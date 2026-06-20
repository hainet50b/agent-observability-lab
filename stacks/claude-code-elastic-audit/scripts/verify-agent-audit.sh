#!/usr/bin/env bash
#
# verify-agent-audit.sh — claude-code-elastic-audit Agent Audit delivery verification.
#
# This stack's integration test for the DIRECT Agent Audit path (hook ->
# Elasticsearch). The audit stack has no OTLP -> APM Server -> Elasticsearch path
# (that is claude-code-elastic's smoke-test.sh). Follows the 3A pattern (see CONVENTIONS.md):
#
#   Arrange — bring the stack up and wait for Elasticsearch (the audit
#             destination) to report healthy. Require that scripts/setup.sh has
#             rendered .claude/settings.local.json (carrying the UserPromptSubmit
#             hook registration) and .claude/agent-audit.conf (the hook's ES
#             delivery config); SKIP with guidance otherwise.
#   Act     — feed a synthetic Claude UserPromptSubmit payload (a unique
#             session_id) on stdin to the RENDERED hook exactly as Claude spawns
#             it — read the command (+ args[] for the exec form) straight from
#             .claude/settings.local.json and run that process. Driving
#             agent-audit.sh directly would not catch a broken rendered hook
#             command, the class of gap this verification guards.
#   Assert  — query logs-agent_audit.user_prompt-default for the canonical
#             agent_audit.user_prompt document carrying that conversation_id;
#             poll until it lands.
#   Cleanup — delete the synthetic verification document (the audit stream must
#             not accumulate test prompts), then print PASS.
#
# Fail-open note: the hook ALWAYS exits 0 (it must never block a prompt — see the
# hook's contract), so the PASS/FAIL signal here is the ASSERTION (the document
# landing in Elasticsearch), never the hook's exit code.
#
# Provider identity (agent_audit.agent.account.* / organization.*) is read from the
# user's ~/.claude.json oauthAccount (not stack-local); without an OAuth session
# those fields are null (valid — the workstation user.id is still derived).
#
# Prerequisites: docker (+ a running daemon), curl, jq. If the daemon is not
# reachable, or setup has not run, the script SKIPs (exit 0) rather than failing.
# Override the ES endpoint with ES_URL if you publish a different port.

set -euo pipefail

ES_URL=${ES_URL:-http://localhost:9200}
DATA_STREAM=logs-agent_audit.user_prompt-default

# Resolve the stack root (parent of this scripts/ dir) and the repo root, so the
# component hook and the stack's .claude/ are found regardless of the caller's cwd.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
STACK_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd -- "$STACK_DIR/../.." && pwd)
HOOK="$REPO_ROOT/components/agents/claude-code/hooks/agent-audit.sh"
CLAUDE_HOME_DIR="$STACK_DIR/.claude"
SETTINGS="$CLAUDE_HOME_DIR/settings.local.json"
cd "$STACK_DIR"

skip() {
  echo "SKIP: $*"
  exit 0
}
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# --- Preconditions ---------------------------------------------------------
command -v docker >/dev/null 2>&1 || skip "docker CLI not found"
command -v curl >/dev/null 2>&1 || skip "curl not found"
command -v jq >/dev/null 2>&1 || skip "jq not found"
docker info >/dev/null 2>&1 || skip "docker daemon not reachable; nothing to verify"
[ -f "$HOOK" ] || fail "hook not found: $HOOK"
[ -f "$SETTINGS" ] || skip "no .claude/settings.local.json — run scripts/setup.sh first"
[ -f "$CLAUDE_HOME_DIR/agent-audit.conf" ] || skip "no .claude/agent-audit.conf — run scripts/setup.sh first"
# Confirm the hook is actually registered on UserPromptSubmit (configured state):
# settings.local.json carries a hooks.UserPromptSubmit entry.
jq -e '.hooks.UserPromptSubmit' "$SETTINGS" >/dev/null 2>&1 ||
  fail "no hooks.UserPromptSubmit registered in .claude/settings.local.json"

# --- Arrange ---------------------------------------------------------------
echo "[arrange] bringing the stack up (docker compose up -d)…"
docker compose up -d

wait_healthy() {
  cname=$1 tries=${2:-60}
  for _ in $(seq 1 "$tries"); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "$cname" 2>/dev/null || echo "")
    [ "$status" = healthy ] && {
      echo "[arrange] $cname healthy"
      return 0
    }
    sleep 5
  done
  return 1
}
wait_healthy aol-elasticsearch 60 || {
  docker compose ps
  fail "aol-elasticsearch did not become healthy"
}

# --- Act -------------------------------------------------------------------
cid="aol-verify-$(date +%s)-$$"
echo "[act] feeding a synthetic UserPromptSubmit payload (conversation_id=$cid) through the configured hook…"

# Shaped like Claude's real UserPromptSubmit payload (the keys the hook reads plus
# the ones it deliberately drops). cwd is included precisely to confirm the strict
# mapping drops it rather than emitting a stray (PII) field. Claude's payload has no
# turn_id and no model.
payload=$(jq -nc --arg cid "$cid" '{
  session_id: $cid,
  prompt: "agent audit verification prompt",
  cwd: "/should/not/be/sent",
  transcript_path: "/should/not/be/sent.jsonl",
  hook_event_name: "UserPromptSubmit",
  permission_mode: "default"
}')

# Spawn the hook EXACTLY as Claude does: read the rendered command (+ args[] for
# the exec form) from settings.local.json and run it with the payload on stdin,
# rather than invoking agent-audit.sh directly — so a broken rendered hook
# command is caught. Claude runs the exec form (command + args[]) as a direct child
# process and a command-string hook through the shell; reproduce both. The config
# path is already baked into the rendered hook. Fail-open: the assertion is the
# real signal.
# tr -d '\r': jq.exe on Windows writes CRLF, so a trailing CR would corrupt each
# exec arg (e.g. "Bypass\r" silently voids -ExecutionPolicy); a no-op on POSIX jq.
hook_command=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$SETTINGS" | tr -d '\r')
if jq -e '.hooks.UserPromptSubmit[0].hooks[0] | has("args")' "$SETTINGS" >/dev/null 2>&1; then
  hook_args=()
  while IFS= read -r a; do hook_args+=("$a"); done \
    < <(jq -r '.hooks.UserPromptSubmit[0].hooks[0].args[]' "$SETTINGS" | tr -d '\r')
  echo "[act] spawning the rendered hook (exec form): $hook_command ${hook_args[*]}"
  printf '%s' "$payload" | "$hook_command" "${hook_args[@]}" || true
else
  echo "[act] spawning the rendered hook (command string via shell): $hook_command"
  printf '%s' "$payload" | sh -c "$hook_command" || true
fi

# --- Assert ----------------------------------------------------------------
es_count_cid() {
  curl -s "$ES_URL/$DATA_STREAM/_count?ignore_unavailable=true&allow_no_indices=true" \
    -H 'Content-Type: application/json' \
    --data "{\"query\":{\"term\":{\"agent_audit.conversation_id\":\"$cid\"}}}" |
    jq -r '.count // 0'
}

echo "[assert] querying $DATA_STREAM for the audit document…"
landed=0
for _ in $(seq 1 30); do
  n=$(es_count_cid)
  if [ "${n:-0}" -ge 1 ]; then
    echo "[assert] found $n audit document(s) for conversation_id=$cid ✓"
    landed=1
    break
  fi
  sleep 2
done
[ "$landed" = 1 ] || fail "no audit document landed in $DATA_STREAM for conversation_id=$cid within timeout"

# Fetch the landed document once for the informational line + assertions.
src=$(curl -s "$ES_URL/$DATA_STREAM/_search?ignore_unavailable=true&allow_no_indices=true" \
  -H 'Content-Type: application/json' \
  --data "{\"size\":1,\"query\":{\"term\":{\"agent_audit.conversation_id\":\"$cid\"}}}" |
  jq -c '.hits.hits[0]._source')
echo "$src" | jq -r '"[assert] document: action=\(.event.action) host.hostname=\(.host.hostname) provider=\(.agent_audit.agent.provider) name=\(.agent_audit.agent.name) turn_id=\(.agent_audit.turn_id) user_prompt.length=\(.agent_audit.user_prompt.length)"'

# Agent constants: provider=anthropic, name=claude-code, and turn_id is null (Claude's
# payload carries none — conversation_id still links to the OTLP session).
[ "$(echo "$src" | jq -r '.agent_audit.agent.provider')" = anthropic ] ||
  fail "agent_audit.agent.provider != anthropic"
[ "$(echo "$src" | jq -r '.agent_audit.agent.name')" = claude-code ] ||
  fail "agent_audit.agent.name != claude-code"
echo "$src" | jq -e '.agent_audit.turn_id == null' >/dev/null ||
  fail "agent_audit.turn_id is not null (Claude payload has no turn id)"
echo "$src" | jq -e '(.agent_audit.agent | has("model")) | not' >/dev/null ||
  fail "audit document carries agent_audit.agent.model — model should be removed from the schema"
echo "[assert] agent constants ok (anthropic/claude-code, turn_id null, no model) ✓"

# Host-enrichment assertion: host.name/host.hostname present.
hhost=$(echo "$src" | jq -r '.host.hostname // empty')
[ -n "$hhost" ] || fail "audit document missing host.hostname — host enrichment or mapping not applied"
echo "[assert] host enrichment present (host.hostname=$hhost) ✓"

# Identity schema: provider account/organization envelope present, and no user.email.
echo "$src" | jq -e '.agent_audit.agent | has("account") and has("organization")' >/dev/null ||
  fail "audit document missing agent_audit.agent.account/organization — identity schema not applied"
echo "$src" | jq -e '(.user | has("email")) | not' >/dev/null ||
  fail "audit document carries user.email — identity schema not applied"
echo "[assert] identity schema applied (account/organization present, no user.email) ✓"

# Identity derivation: user.id is the workstation login, always derivable via whoami.
uid=$(echo "$src" | jq -r '.user.id // empty')
[ -n "$uid" ] || fail "audit document missing user.id — identity derivation not applied"
echo "[assert] user.id derived (user.id=$uid) ✓"

# Provider account.id is read from ~/.claude.json's oauthAccount; populated only for
# an OAuth session (API-key / unauthenticated -> null is valid, so informational).
acct=$(echo "$src" | jq -r '.agent_audit.agent.account.id // empty')
if [ -n "$acct" ]; then
  echo "[assert] provider account.id derived from ~/.claude.json (account.id=$acct) ✓"
else
  echo "[assert] account.id null — no OAuth session in ~/.claude.json (valid; user.id still derived)"
fi

# --- Cleanup ---------------------------------------------------------------
echo "[cleanup] removing the synthetic verification document…"
curl -s -X POST "$ES_URL/$DATA_STREAM/_delete_by_query?refresh=true&ignore_unavailable=true" \
  -H 'Content-Type: application/json' \
  --data "{\"query\":{\"term\":{\"agent_audit.conversation_id\":\"$cid\"}}}" |
  jq -r '"[cleanup] deleted \(.deleted // 0) document(s)"'

echo
echo "PASS: Claude Code UserPromptSubmit hook -> $DATA_STREAM delivery verified."
