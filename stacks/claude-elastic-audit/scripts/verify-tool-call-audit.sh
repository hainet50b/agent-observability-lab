#!/usr/bin/env bash

set -euo pipefail

ES_URL=${ES_URL:-http://localhost:9200}
DATA_STREAM=logs-agent_audit.tool_call-default

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
STACK_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
HOOK="$STACK_DIR/.claude/hooks/agent-audit.sh"
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

command -v docker >/dev/null 2>&1 || skip "docker CLI not found"
command -v curl >/dev/null 2>&1 || skip "curl not found"
command -v jq >/dev/null 2>&1 || skip "jq not found"
docker info >/dev/null 2>&1 || skip "docker daemon not reachable; nothing to verify"
[ -f "$HOOK" ] || fail "hook not found: $HOOK"
[ -f "$SETTINGS" ] || skip "no .claude/settings.local.json — run scripts/setup.sh first"
[ -f "$CLAUDE_HOME_DIR/hooks/agent-audit.conf" ] || skip "no .claude/hooks/agent-audit.conf — run scripts/setup.sh first"
jq -e '.hooks.PostToolUse' "$SETTINGS" >/dev/null 2>&1 ||
  fail "no hooks.PostToolUse registered in .claude/settings.local.json"

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

cid="aol-verify-tc-$(date +%s)-$$"
echo "[act] feeding a synthetic PostToolUse payload (conversation_id=$cid) through the configured hook…"

payload=$(jq -nc --arg cid "$cid" '{
  session_id: $cid,
  turn_id: "verify-turn-1",
  tool_name: "Bash",
  tool_use_id: "call_verify_0001",
  tool_input: { command: "echo hello", description: "verify" },
  tool_response: "hello\n",
  cwd: "/should/not/be/sent",
  transcript_path: "/should/not/be/sent.jsonl",
  hook_event_name: "PostToolUse",
  permission_mode: "auto"
}')

# tr -d '\r': jq.exe on Windows writes CRLF, so a trailing CR would corrupt each exec
# arg (e.g. "Bypass\r" silently voids -ExecutionPolicy); a no-op on POSIX jq.
hook_command=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$SETTINGS" | tr -d '\r')
if jq -e '.hooks.PostToolUse[0].hooks[0] | has("args")' "$SETTINGS" >/dev/null 2>&1; then
  hook_args=()
  while IFS= read -r a; do hook_args+=("$a"); done \
    < <(jq -r '.hooks.PostToolUse[0].hooks[0].args[]' "$SETTINGS" | tr -d '\r')
  echo "[act] spawning the rendered hook (exec form): $hook_command ${hook_args[*]}"
  printf '%s' "$payload" | "$hook_command" "${hook_args[@]}" || true
else
  echo "[act] spawning the rendered hook (command string via shell): $hook_command"
  printf '%s' "$payload" | sh -c "$hook_command" || true
fi

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

src=$(curl -s "$ES_URL/$DATA_STREAM/_search?ignore_unavailable=true&allow_no_indices=true" \
  -H 'Content-Type: application/json' \
  --data "{\"size\":1,\"query\":{\"term\":{\"agent_audit.conversation_id\":\"$cid\"}}}" |
  jq -c '.hits.hits[0]._source')
echo "$src" | jq -r '"[assert] document: action=\(.event.action) tool=\(.agent_audit.tool_call.tool.name) call_id=\(.agent_audit.tool_call.tool.call_id) turn_id=\(.agent_audit.turn_id) input.length=\(.agent_audit.tool_call.input.length) output.length=\(.agent_audit.tool_call.output.length)"'

[ "$(echo "$src" | jq -r '.event.action')" = tool-call ] || fail "event.action is not 'tool-call'"
[ "$(echo "$src" | jq -r '.event.dataset')" = agent_audit.tool_call ] || fail "event.dataset is not 'agent_audit.tool_call'"

[ "$(echo "$src" | jq -r '.agent_audit.tool_call.tool.name // empty')" = Bash ] || fail "tool.name not captured"
[ "$(echo "$src" | jq -r '.agent_audit.tool_call.tool.call_id // empty')" = call_verify_0001 ] || fail "tool.call_id not captured (tool_use_id mapping)"

[ "$(echo "$src" | jq -r '.agent_audit.agent.provider')" = anthropic ] || fail "agent_audit.agent.provider != anthropic"
[ "$(echo "$src" | jq -r '.agent_audit.agent.name')" = claude ] || fail "agent_audit.agent.name != claude"
[ "$(echo "$src" | jq -r '.agent_audit.turn_id // empty')" = verify-turn-1 ] || fail "agent_audit.turn_id not captured (turn_id mapping)"
echo "$src" | jq -e '(.agent_audit.agent | has("model")) | not' >/dev/null ||
  fail "audit document carries agent_audit.agent.model — model should be removed from the schema"
echo "[assert] agent constants ok (anthropic/claude, turn_id captured, no model) ✓"

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

hhost=$(echo "$src" | jq -r '.host.hostname // empty')
[ -n "$hhost" ] || fail "audit document missing host.hostname — host enrichment or mapping not applied"
uid=$(echo "$src" | jq -r '.user.id // empty')
[ -n "$uid" ] || fail "audit document missing user.id — identity derivation not applied"
echo "$src" | jq -e '(.user | has("email")) | not' >/dev/null ||
  fail "audit document carries user.email — identity schema not applied"
echo "$src" | jq -e '.agent_audit.agent | has("account") and has("organization")' >/dev/null ||
  fail "audit document missing agent_audit.agent.account/organization — identity schema not applied"
echo "[assert] identity present (user.id=$uid, host.hostname=$hhost, no user.email, account/organization envelope) ✓"

acct=$(echo "$src" | jq -r '.agent_audit.agent.account.id // empty')
if [ -n "$acct" ]; then
  echo "[assert] provider account.id derived from ~/.claude.json (account.id=$acct) ✓"
else
  echo "[assert] account.id null — no OAuth session in ~/.claude.json (valid; user.id still derived)"
fi

echo "[cleanup] removing the synthetic verification document…"
curl -s -X POST "$ES_URL/$DATA_STREAM/_delete_by_query?refresh=true&ignore_unavailable=true" \
  -H 'Content-Type: application/json' \
  --data "{\"query\":{\"term\":{\"agent_audit.conversation_id\":\"$cid\"}}}" |
  jq -r '"[cleanup] deleted \(.deleted // 0) document(s)"'

echo
echo "PASS: Claude Code PostToolUse hook -> $DATA_STREAM delivery verified."
