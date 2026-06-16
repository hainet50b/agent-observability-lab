#!/usr/bin/env bash
#
# verify-tool-call-audit.sh — codex-cli-elastic-audit Agent Audit tool-call verification.
#
# Sibling of verify-agent-audit.sh (which covers the UserPromptSubmit -> user_prompt
# stream path); this one covers the DIRECT Agent Audit tool-call path (Codex's
# PostToolUse hook -> logs-agent_audit.tool_call-default). The audit stack has no
# OTLP/APM path (that is codex-cli-elastic's smoke-test.sh). Follows the 3A pattern (see CONVENTIONS.md):
#
#   Arrange — bring the stack up and wait for Elasticsearch (the audit destination)
#             healthy. Require scripts/setup.sh to have rendered .codex/hooks.json
#             (the PostToolUse registration) and .codex/agent-audit.toml (the hook's
#             ES delivery config); SKIP with guidance otherwise.
#   Act     — feed a synthetic Codex PostToolUse payload (a unique session_id, an
#             object tool_input and a string tool_response — the heterogeneous shapes
#             the hook serializes) on stdin to the configured PostToolUse hook
#             (components/agents/codex-cli/hooks/capture-tool-call.sh), with
#             CODEX_HOME=<stack>/.codex so it reads this stack's delivery config,
#             exactly as a real Codex session invokes it.
#   Assert  — query logs-agent_audit.tool_call-default for the canonical
#             agent_audit.tool_call document carrying that conversation_id; poll
#             until it lands, then check the tool identity, the serialized-to-string
#             input/output bodies, and the identity envelope.
#   Cleanup — delete the synthetic verification document, then print PASS.
#
# Fail-open note: the hook ALWAYS exits 0 (it must never block a tool call — see the
# hook's contract), so the PASS/FAIL signal here is the ASSERTION (the document
# landing in Elasticsearch), never the hook's exit code.
#
# Prerequisites: docker (+ a running daemon), curl, jq. If the daemon is not
# reachable, or setup has not run, the script SKIPs (exit 0) rather than failing.
# Override the ES endpoint with ES_URL if you publish a different port.

set -euo pipefail

ES_URL=${ES_URL:-http://localhost:9200}
DATA_STREAM=logs-agent_audit.tool_call-default

# Resolve the stack root (parent of this scripts/ dir) and the repo root, so the
# component hook and the stack's .codex/ are found regardless of the caller's cwd.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STACK_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd -- "$STACK_DIR/../.." && pwd)
HOOK="$REPO_ROOT/components/agents/codex-cli/hooks/capture-tool-call.sh"
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
# Confirm the hook is actually registered on PostToolUse (configured state).
jq -e '.hooks.PostToolUse[0].hooks[0].command' "$CODEX_HOME_DIR/hooks.json" >/dev/null 2>&1 \
  || fail "no PostToolUse command registered in .codex/hooks.json"

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
cid="aol-verify-tc-$(date +%s)-$$"
echo "[act] feeding a synthetic PostToolUse payload (conversation_id=$cid) through the configured hook…"

# Shaped like Codex's real PostToolUse payload: an OBJECT tool_input and a STRING
# tool_response (the two heterogeneous shapes the hook serializes to a JSON string).
# cwd / transcript_path / permission_mode are included precisely to confirm the
# strict mapping drops them rather than emitting stray (PII) fields.
payload=$(jq -nc --arg cid "$cid" '{
  session_id: $cid,
  turn_id: "verify-turn-1",
  model: "verify-model",
  tool_name: "Bash",
  tool_use_id: "call_verify_0001",
  tool_input: { command: "echo hello", description: "verify" },
  tool_response: "hello\n",
  cwd: "/should/not/be/sent",
  transcript_path: "/should/not/be/sent.jsonl",
  hook_event_name: "PostToolUse",
  permission_mode: "auto"
}')

# Run the configured hook with CODEX_HOME pointed at this stack's .codex so it reads
# the rendered agent-audit.toml. The hook is fail-open (always exit 0); the assertion
# below — not this exit code — is the real signal.
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

# Fetch the landed document once for the informational line and the field assertions.
src=$(curl -s "$ES_URL/$DATA_STREAM/_search?ignore_unavailable=true&allow_no_indices=true" \
  -H 'Content-Type: application/json' \
  --data "{\"size\":1,\"query\":{\"term\":{\"agent_audit.conversation_id\":\"$cid\"}}}" \
  | jq -c '.hits.hits[0]._source')
echo "$src" | jq -r '"[assert] document: action=\(.event.action) tool=\(.agent_audit.tool_call.tool.name) call_id=\(.agent_audit.tool_call.tool.call_id) input.length=\(.agent_audit.tool_call.input.length) output.length=\(.agent_audit.tool_call.output.length)"'

# event.action / dataset must be the tool-call variant.
[ "$(echo "$src" | jq -r '.event.action')"  = tool-call ]              || fail "event.action is not 'tool-call'"
[ "$(echo "$src" | jq -r '.event.dataset')" = agent_audit.tool_call ]  || fail "event.dataset is not 'agent_audit.tool_call'"

# Tool identity present.
[ "$(echo "$src" | jq -r '.agent_audit.tool_call.tool.name // empty')"    = Bash ]             || fail "tool.name not captured"
[ "$(echo "$src" | jq -r '.agent_audit.tool_call.tool.call_id // empty')" = call_verify_0001 ] || fail "tool.call_id not captured (tool_use_id mapping)"

# Heterogeneous tool I/O serialized to a JSON STRING into .text (plaintext mode), with
# .length the char count. The input object becomes JSON whose key we can grep for.
in_text=$(echo "$src" | jq -r '.agent_audit.tool_call.input.text // empty')
[ -n "$in_text" ] || fail "input.text empty — tool_input not serialized (plaintext mode expected)"
echo "$in_text" | grep -q 'command' || fail "input.text does not look like serialized tool_input JSON"
in_len=$(echo "$src" | jq -r '.agent_audit.tool_call.input.length // 0')
[ "$in_len" -gt 0 ] || fail "input.length not recorded"
out_text=$(echo "$src" | jq -r '.agent_audit.tool_call.output.text // empty')
[ -n "$out_text" ] || fail "output.text empty — tool_response not serialized (plaintext mode expected)"
out_len=$(echo "$src" | jq -r '.agent_audit.tool_call.output.length // 0')
[ "$out_len" -gt 0 ] || fail "output.length not recorded"
echo "[assert] tool I/O serialized to .text with lengths (input=$in_len, output=$out_len) ✓"

# Identity envelope: workstation login + provider account/organization shape (the
# same derivation as user prompts), and the dropped fields stay out (strict mapping
# would have rejected the doc otherwise — it landed, so they were dropped).
hhost=$(echo "$src" | jq -r '.host.hostname // empty')
[ -n "$hhost" ] || fail "audit document missing host.hostname — host enrichment or mapping not applied"
uid=$(echo "$src" | jq -r '.user.id // empty')
[ -n "$uid" ] || fail "audit document missing user.id — identity derivation not applied"
echo "$src" | jq -e '.agent_audit.agent | has("account") and has("organization")' >/dev/null \
  || fail "audit document missing agent_audit.agent.account/organization — identity schema not applied"
echo "[assert] identity present (user.id=$uid, host.hostname=$hhost, account/organization envelope) ✓"

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
echo "PASS: Codex PostToolUse hook -> $DATA_STREAM delivery verified."
