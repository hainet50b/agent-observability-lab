#!/usr/bin/env bash
#
# setup-prompt-audit.sh — create the `prompts-audit` Elasticsearch index.
#
# The audit store is the destination of the agent-side prompt-capture hook
# (components/agents/claude-code/hooks/capture-prompt.*), which POSTs one
# document per submitted prompt over a path **independent of the OTLP analytics
# pipeline** (it talks straight to Elasticsearch, not the APM Server / Collector).
# This is the organization's "when / who / what prompt" audit trail; the existing
# metrics/events/traces analytics keeps flowing untouched.
#
# The index is owned by the **backend** (not the agent) because it is
# agent-agnostic — a future codex / opencode capture would land here too, keyed
# by the `agent` field. The mapping is the single source of truth in
# elasticsearch/prompts-audit.index.json:
#   - dynamic: strict        — a hook bug fails loud rather than growing stray fields
#   - envelope (keyword)     — agent / user_email / organization / session_id /
#                              hostname: the searchable "who / when" (cwd is
#                              intentionally excluded — it is PII; see the hook)
#   - prompt (text)          — the captured content (plaintext phase)
#   - prompt_cipher (keyword, index/doc_values off) — defined up front so the
#                              later public-key-sealing phase swaps prompt →
#                              prompt_cipher with no mapping change
#
# This is a plain prototype index. Production would promote it to a data stream
# with ILM (retention == the deletion requirement); out of scope here.
#
# Idempotent: if the index already exists it is left as-is (a create-index PUT is
# NOT idempotent, so we check first rather than blindly PUT).
#
# Prerequisites: curl, jq. Override the Elasticsearch base URL with ES_URL if you
# publish a different port than the default below.
#
#   ES_URL=http://localhost:9200  scripts/setup-prompt-audit.sh
#
# Run from anywhere — it locates its own component directory like the others.

set -euo pipefail

ES_URL=${ES_URL:-http://localhost:9200}
INDEX=prompts-audit
INDEX_FILE=elasticsearch/prompts-audit.index.json

# Resolve and enter the component root (parent of this scripts/ directory) so the
# elasticsearch/ path resolves regardless of the caller's cwd.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$COMPONENT_DIR"

skip() { echo "SKIP: $*"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || skip "curl not found"
command -v jq   >/dev/null 2>&1 || skip "jq not found"

[ -f "$INDEX_FILE" ] || fail "index mapping not found: $COMPONENT_DIR/$INDEX_FILE"

# Already there? Leave it untouched (idempotent).
existing=$(curl -s -o /dev/null -w '%{http_code}' "$ES_URL/$INDEX") || fail "request to Elasticsearch failed"
if [ "$existing" = 200 ]; then
  echo "[setup] index '$INDEX' already exists — leaving as-is"
  echo "PASS: prompt-audit store '$INDEX' present on $ES_URL"
  exit 0
fi

echo "[setup] creating index '$INDEX' on $ES_URL…"
result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/$INDEX" \
  -H 'Content-Type: application/json' --data "@$INDEX_FILE") || fail "request to Elasticsearch failed"

code=$(echo "$result" | tail -n1)
body=$(echo "$result" | sed '$d')

echo "$body" | jq . 2>/dev/null || echo "$body"

case "$code" in
  2*) : ;;
  *) fail "PUT /$INDEX returned HTTP $code (expected 2xx)" ;;
esac

acknowledged=$(echo "$body" | jq -r '.acknowledged // false')
[ "$acknowledged" = true ] || fail "index create not acknowledged"

echo "[setup] index '$INDEX' created ✓"
echo
echo "PASS: prompt-audit store '$INDEX' ready on $ES_URL. Register the capture hook"
echo "(see ../../agents/claude-code/hooks/ and the stack README) and submit a"
echo "prompt; the document lands in '$INDEX', independent of the OTLP pipeline."
