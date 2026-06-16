#!/usr/bin/env bash
#
# verify-agent-audit.sh — codex-cli-elastic Agent Audit delivery verification.
#
# Sibling of smoke-test.sh, but for the DIRECT Agent Audit path (hook ->
# Elasticsearch) rather than the OTLP -> APM Server -> Elasticsearch path that
# smoke-test.sh covers. Follows the 3A pattern (see CONVENTIONS.md):
#
#   Arrange — bring the stack up and wait for Elasticsearch (the audit
#             destination) to report healthy. Require that scripts/setup.sh has
#             rendered .codex/hooks.json (the UserPromptSubmit registration) and
#             .codex/agent-audit.toml (the hook's ES delivery config); SKIP with
#             guidance otherwise.
#   Act     — feed a synthetic Codex UserPromptSubmit payload (a unique
#             session_id) on stdin to the configured UserPromptSubmit hook
#             (components/agents/codex-cli/hooks/capture-user-prompt.sh — the same
#             script .codex/hooks.json registers), with CODEX_HOME=<stack>/.codex
#             so it reads this stack's rendered delivery config, exactly as a real
#             Codex session invokes it.
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
# Prerequisites: docker (+ a running daemon), curl, jq. If the daemon is not
# reachable, or setup has not run, the script SKIPs (exit 0) rather than failing.
# Override the ES endpoint with ES_URL if you publish a different port.

set -euo pipefail

ES_URL=${ES_URL:-http://localhost:9200}
DATA_STREAM=logs-agent_audit.user_prompt-default

# Resolve the stack root (parent of this scripts/ dir) and the repo root, so the
# component hook and the stack's .codex/ are found regardless of the caller's cwd.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STACK_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd -- "$STACK_DIR/../.." && pwd)
HOOK="$REPO_ROOT/components/agents/codex-cli/hooks/capture-user-prompt.sh"
CODEX_HOME_DIR="$STACK_DIR/.codex"
cd "$STACK_DIR"

skip() { echo "SKIP: $*"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Preconditions ---------------------------------------------------------
command -v docker >/dev/null 2>&1 || skip "docker CLI not found"
command -v curl   >/dev/null 2>&1 || skip "curl not found"
command -v jq     >/dev/null 2>&1 || skip "jq not found"
docker info >/dev/null 2>&1        || skip "docker daemon not reachable; nothing to verify"
[ -f "$HOOK" ] || fail "hook not found: $HOOK"
[ -f "$CODEX_HOME_DIR/hooks.json" ]       || skip "no .codex/hooks.json — run scripts/setup.sh first"
[ -f "$CODEX_HOME_DIR/agent-audit.toml" ] || skip "no .codex/agent-audit.toml — run scripts/setup.sh first"
# Confirm the hook is actually registered on UserPromptSubmit (configured state).
jq -e '.hooks.UserPromptSubmit[0].hooks[0].command' "$CODEX_HOME_DIR/hooks.json" >/dev/null 2>&1 \
  || fail "no UserPromptSubmit command registered in .codex/hooks.json"

# --- Arrange ---------------------------------------------------------------
echo "[arrange] bringing the stack up (docker compose up -d)…"
docker compose up -d

wait_healthy() {
  cname=$1 tries=${2:-60}
  for _ in $(seq 1 "$tries"); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "$cname" 2>/dev/null || echo "")
    [ "$status" = healthy ] && { echo "[arrange] $cname healthy"; return 0; }
    sleep 5
  done
  return 1
}
wait_healthy aol-elasticsearch 60 || { docker compose ps; fail "aol-elasticsearch did not become healthy"; }

# --- Act -------------------------------------------------------------------
cid="aol-verify-$(date +%s)-$$"
echo "[act] feeding a synthetic UserPromptSubmit payload (conversation_id=$cid) through the configured hook…"

# Shaped like Codex's real UserPromptSubmit payload (the keys the hook reads plus
# the ones it deliberately drops). cwd is included precisely to confirm the strict
# mapping drops it rather than emitting a stray (PII) field.
payload=$(jq -nc --arg cid "$cid" '{
  session_id: $cid,
  turn_id: "verify-turn-1",
  model: "verify-model",
  prompt: "agent audit verification prompt",
  cwd: "/should/not/be/sent",
  transcript_path: "/should/not/be/sent.jsonl",
  hook_event_name: "UserPromptSubmit",
  permission_mode: "auto"
}')

# Run the configured hook with CODEX_HOME pointed at this stack's .codex so it
# reads the rendered agent-audit.toml. The hook is fail-open (always exit 0); the
# assertion below — not this exit code — is the real signal.
printf '%s' "$payload" | CODEX_HOME="$CODEX_HOME_DIR" bash "$HOOK" || true

# --- Assert ----------------------------------------------------------------
es_count_cid() {
  curl -s "$ES_URL/$DATA_STREAM/_count?ignore_unavailable=true&allow_no_indices=true" \
    -H 'Content-Type: application/json' \
    --data "{\"query\":{\"term\":{\"agent_audit.conversation_id\":\"$cid\"}}}" \
    | jq -r '.count // 0'
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

# Fetch the landed document once for the informational line + the host-enrichment
# assertion (host.name/host.hostname must be present — added to the strict mapping
# and emitted by the hook).
src=$(curl -s "$ES_URL/$DATA_STREAM/_search?ignore_unavailable=true&allow_no_indices=true" \
  -H 'Content-Type: application/json' \
  --data "{\"size\":1,\"query\":{\"term\":{\"agent_audit.conversation_id\":\"$cid\"}}}" \
  | jq -c '.hits.hits[0]._source')
echo "$src" | jq -r '"[assert] document: action=\(.event.action) host.name=\(.host.name) host.hostname=\(.host.hostname) provider=\(.agent_audit.agent.provider) model=\(.agent_audit.agent.model) user_prompt.length=\(.agent_audit.user_prompt.length)"'
hhost=$(echo "$src" | jq -r '.host.hostname // empty')
[ -n "$hhost" ] || fail "audit document missing host.hostname — host enrichment or mapping not applied"
echo "[assert] host enrichment present (host.hostname=$hhost) ✓"

# Identity schema (SPEC update): provider account/organization envelope present,
# and user.email gone.
echo "$src" | jq -e '.agent_audit.agent | has("account") and has("organization")' >/dev/null \
  || fail "audit document missing agent_audit.agent.account/organization — identity schema not applied"
echo "$src" | jq -e '(.user | has("email")) | not' >/dev/null \
  || fail "audit document still carries user.email — identity schema not applied"
echo "[assert] identity schema applied (account/organization present, no user.email) ✓"

# Identity derivation (SPEC "Identity derivation"): user.id is the domain-qualified
# workstation login, always derivable via whoami; account.id is read from
# CODEX_HOME/auth.json and is populated only when that ChatGPT-auth file exists
# (API-key auth / no file -> null is valid, so only assert it when present).
uid=$(echo "$src" | jq -r '.user.id // empty')
[ -n "$uid" ] || fail "audit document missing user.id — identity derivation not applied"
echo "[assert] user.id derived (user.id=$uid) ✓"

if [ -f "$CODEX_HOME_DIR/auth.json" ]; then
  acct=$(echo "$src" | jq -r '.agent_audit.agent.account.id // empty')
  [ -n "$acct" ] || fail "auth.json present but agent_audit.agent.account.id not populated — provider identity derivation not applied"
  echo "[assert] provider account.id derived from $CODEX_HOME_DIR/auth.json (account.id=$acct) ✓"
else
  echo "[assert] no $CODEX_HOME_DIR/auth.json — skipping provider account.id assertion (API-key auth / null is valid)"
fi

# --- Cleanup ---------------------------------------------------------------
echo "[cleanup] removing the synthetic verification document…"
curl -s -X POST "$ES_URL/$DATA_STREAM/_delete_by_query?refresh=true&ignore_unavailable=true" \
  -H 'Content-Type: application/json' \
  --data "{\"query\":{\"term\":{\"agent_audit.conversation_id\":\"$cid\"}}}" \
  | jq -r '"[cleanup] deleted \(.deleted // 0) document(s)"'

echo
echo "PASS: Codex UserPromptSubmit hook -> $DATA_STREAM delivery verified."
