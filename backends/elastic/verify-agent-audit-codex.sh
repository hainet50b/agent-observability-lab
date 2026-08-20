#!/usr/bin/env bash

set -euo pipefail

ES_URL=${ES_URL:-http://localhost:9200}
UP_STREAM=logs-agent_audit.user_prompt-default
TC_STREAM=logs-agent_audit.tool_call-default

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
WORKBENCH=${1:-${AOL_WORKBENCH:-}}
if [ -z "$WORKBENCH" ]; then
  echo "FAIL: usage: verify-agent-audit-codex.sh <workbench-dir>  (or set AOL_WORKBENCH) — the directory agent config was placed into" >&2
  exit 1
fi
WORKBENCH=$(CDPATH='' cd -- "$WORKBENCH" && pwd)
HOOK="$WORKBENCH/.codex/hooks/agent-audit.sh"
CODEX_HOME_DIR="$WORKBENCH/.codex"

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
[ -f "$CODEX_HOME_DIR/config.toml" ] || skip "no .codex/config.toml in the workbench — run agent-config place first (see README.md)"
[ -f "$CODEX_HOME_DIR/hooks/agent-audit.conf" ] || skip "no .codex/hooks/agent-audit.conf in the workbench — run agent-config place first (see README.md)"
grep -qF '[[hooks.UserPromptSubmit]]' "$CODEX_HOME_DIR/config.toml" ||
  fail "no [[hooks.UserPromptSubmit]] registered in .codex/config.toml"
grep -qF '[[hooks.PostToolUse]]' "$CODEX_HOME_DIR/config.toml" ||
  fail "no [[hooks.PostToolUse]] registered in .codex/config.toml"

echo "[arrange] bringing the backend up (docker compose up -d)…"
docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d

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
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps
  fail "aol-elasticsearch did not become healthy"
}

es_count() {
  stream=$1 cid=$2
  curl -s "$ES_URL/$stream/_count?ignore_unavailable=true&allow_no_indices=true" \
    -H 'Content-Type: application/json' \
    --data "{\"query\":{\"term\":{\"agent_audit.conversation_id\":\"$cid\"}}}" |
    jq -r '.count // 0'
}

assert_landed() {
  stream=$1 cid=$2
  echo "[assert] querying $stream for the audit document…"
  for _ in $(seq 1 30); do
    n=$(es_count "$stream" "$cid")
    if [ "${n:-0}" -ge 1 ]; then
      echo "[assert] found $n audit document(s) for conversation_id=$cid ✓"
      return 0
    fi
    sleep 2
  done
  fail "no audit document landed in $stream for conversation_id=$cid within timeout"
}

fetch_src() {
  stream=$1 cid=$2
  curl -s "$ES_URL/$stream/_search?ignore_unavailable=true&allow_no_indices=true" \
    -H 'Content-Type: application/json' \
    --data "{\"size\":1,\"query\":{\"term\":{\"agent_audit.conversation_id\":\"$cid\"}}}" |
    jq -c '.hits.hits[0]._source'
}

cleanup_doc() {
  stream=$1 cid=$2
  curl -s -X POST "$ES_URL/$stream/_delete_by_query?refresh=true&ignore_unavailable=true" \
    -H 'Content-Type: application/json' \
    --data "{\"query\":{\"term\":{\"agent_audit.conversation_id\":\"$cid\"}}}" |
    jq -r '"[cleanup] deleted \(.deleted // 0) document(s)"'
}

assert_account_id() {
  src=$1
  if [ -f "$CODEX_HOME_DIR/auth.json" ]; then
    acct=$(echo "$src" | jq -r '.agent_audit.agent.account.id // empty')
    [ -n "$acct" ] || fail "auth.json present but agent_audit.agent.account.id not populated — provider identity derivation not applied"
    echo "[assert] provider account.id derived from $CODEX_HOME_DIR/auth.json (account.id=$acct) ✓"
  else
    echo "[assert] no $CODEX_HOME_DIR/auth.json — skipping provider account.id assertion (API-key auth / null is valid)"
  fi
}

# --- user_prompt stream ---

cid="aol-verify-$(date +%s)-$$"
echo "[act] feeding a synthetic UserPromptSubmit payload (conversation_id=$cid) through the configured hook…"

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

printf '%s' "$payload" | CODEX_HOME="$CODEX_HOME_DIR" bash "$HOOK" --stream user_prompt --config "$CODEX_HOME_DIR/hooks/agent-audit.conf" || true

assert_landed "$UP_STREAM" "$cid"
src=$(fetch_src "$UP_STREAM" "$cid")
echo "$src" | jq -r '"[assert] document: action=\(.event.action) host.name=\(.host.name) host.hostname=\(.host.hostname) provider=\(.agent_audit.agent.provider) model=\(.agent_audit.agent.model) user_prompt.length=\(.agent_audit.user_prompt.length)"'
hhost=$(echo "$src" | jq -r '.host.hostname // empty')
[ -n "$hhost" ] || fail "audit document missing host.hostname — host enrichment or mapping not applied"
echo "[assert] host enrichment present (host.hostname=$hhost) ✓"

echo "$src" | jq -e '.agent_audit.agent | has("account") and has("organization")' >/dev/null ||
  fail "audit document missing agent_audit.agent.account/organization — identity schema not applied"
echo "$src" | jq -e '(.user | has("email")) | not' >/dev/null ||
  fail "audit document still carries user.email — identity schema not applied"
echo "[assert] identity schema applied (account/organization present, no user.email) ✓"

uid=$(echo "$src" | jq -r '.user.id // empty')
[ -n "$uid" ] || fail "audit document missing user.id — identity derivation not applied"
echo "[assert] user.id derived (user.id=$uid) ✓"

assert_account_id "$src"

echo "[cleanup] removing the synthetic verification document…"
cleanup_doc "$UP_STREAM" "$cid"

# --- tool_call stream ---

cid="aol-verify-tc-$(date +%s)-$$"
echo "[act] feeding a synthetic PostToolUse payload (conversation_id=$cid) through the configured hook…"

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

printf '%s' "$payload" | CODEX_HOME="$CODEX_HOME_DIR" bash "$HOOK" --stream tool_call --config "$CODEX_HOME_DIR/hooks/agent-audit.conf" || true

assert_landed "$TC_STREAM" "$cid"
src=$(fetch_src "$TC_STREAM" "$cid")
echo "$src" | jq -r '"[assert] document: action=\(.event.action) tool=\(.agent_audit.tool_call.tool.name) call_id=\(.agent_audit.tool_call.tool.call_id) input.length=\(.agent_audit.tool_call.input.length) output.length=\(.agent_audit.tool_call.output.length)"'

[ "$(echo "$src" | jq -r '.event.action')" = tool-call ] || fail "event.action is not 'tool-call'"
[ "$(echo "$src" | jq -r '.event.dataset')" = agent_audit.tool_call ] || fail "event.dataset is not 'agent_audit.tool_call'"

[ "$(echo "$src" | jq -r '.agent_audit.tool_call.tool.name // empty')" = Bash ] || fail "tool.name not captured"
[ "$(echo "$src" | jq -r '.agent_audit.tool_call.tool.call_id // empty')" = call_verify_0001 ] || fail "tool.call_id not captured (tool_use_id mapping)"

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
echo "$src" | jq -e '.agent_audit.agent | has("account") and has("organization")' >/dev/null ||
  fail "audit document missing agent_audit.agent.account/organization — identity schema not applied"
echo "[assert] identity present (user.id=$uid, host.hostname=$hhost, account/organization envelope) ✓"

assert_account_id "$src"

echo "[cleanup] removing the synthetic verification document…"
cleanup_doc "$TC_STREAM" "$cid"

echo
echo "PASS: Codex UserPromptSubmit + PostToolUse hooks -> agent_audit stream delivery verified."
