#!/usr/bin/env bash
#
# setup-agent-audit.sh — provision the Agent Audit user-prompt data stream.
#
# Direct agent-audit records (hook-captured user prompts) live in a dedicated
# Elasticsearch **log data stream**, separate from the OTLP/APM telemetry streams
# (see SPEC/agent-audit.md). The stream is **agent-cross-cutting**: the AI agent
# (Codex CLI / Claude Code / …) is a document field (agent_audit.agent.*), not a
# segment of the data stream name — so a future codex/claude/opencode capture all
# land in the same store, keyed by that field. That is why this is **backend-owned**
# (like setup-prompt-audit.sh), not agent-owned.
#
# This creates two things from the single source of truth in
# elasticsearch/agent-audit.user_prompt.template.json:
#   1. the composable index template `logs-agent_audit.user_prompt`
#      (index_patterns: logs-agent_audit.user_prompt-*, data_stream: {}, strict
#       mappings, priority 200 to win over the built-in `logs-*-*` template, and a
#       30-day data-stream lifecycle == the lab's default audit retention), and
#   2. the data stream `logs-agent_audit.user_prompt-default` itself.
#
# The mapping is `dynamic: strict` on purpose: a hook bug that emits an unexpected
# field fails the index rather than silently growing the audit schema. The setup
# credentials used here own template / data-stream / mapping creation; the hook's
# own write credentials should be scoped to create-only document ingestion on
# logs-agent_audit.user_prompt-* (see SPEC/agent-audit.md "Delivery and
# authorization").
#
# Idempotent: the template PUT replaces in place; the data stream is created only
# if absent (a create is not idempotent, so we check first).
#
# Prerequisites: curl, jq. Override the Elasticsearch base URL with ES_URL if you
# publish a different port than the default below.
#
#   ES_URL=http://localhost:9200  scripts/setup-agent-audit.sh
#
# Run from anywhere — it locates its own component directory like the others.

set -euo pipefail

ES_URL=${ES_URL:-http://localhost:9200}
TEMPLATE=logs-agent_audit.user_prompt
DATA_STREAM=logs-agent_audit.user_prompt-default
TEMPLATE_FILE=elasticsearch/agent-audit.user_prompt.template.json

# Resolve and enter the component root (parent of this scripts/ directory) so the
# elasticsearch/ path resolves regardless of the caller's cwd.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$COMPONENT_DIR"

skip() { echo "SKIP: $*"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || skip "curl not found"
command -v jq   >/dev/null 2>&1 || skip "jq not found"

[ -f "$TEMPLATE_FILE" ] || fail "index template not found: $COMPONENT_DIR/$TEMPLATE_FILE"

# 1. Install / replace the composable index template (idempotent).
echo "[setup] installing index template '$TEMPLATE' on $ES_URL…"
result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/_index_template/$TEMPLATE" \
  -H 'Content-Type: application/json' --data "@$TEMPLATE_FILE") || fail "request to Elasticsearch failed"

code=$(echo "$result" | tail -n1)
body=$(echo "$result" | sed '$d')
echo "$body" | jq . 2>/dev/null || echo "$body"

case "$code" in
  2*) : ;;
  *) fail "PUT _index_template/$TEMPLATE returned HTTP $code (expected 2xx)" ;;
esac

acknowledged=$(echo "$body" | jq -r '.acknowledged // false')
[ "$acknowledged" = true ] || fail "index template PUT not acknowledged"
echo "[setup] index template '$TEMPLATE' installed ✓"

# 2. Create the data stream if it does not already exist (PUT is not idempotent).
existing=$(curl -s -o /dev/null -w '%{http_code}' "$ES_URL/_data_stream/$DATA_STREAM") || fail "request to Elasticsearch failed"
if [ "$existing" = 200 ]; then
  echo "[setup] data stream '$DATA_STREAM' already exists — leaving as-is"
else
  echo "[setup] creating data stream '$DATA_STREAM' on $ES_URL…"
  result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/_data_stream/$DATA_STREAM") || fail "request to Elasticsearch failed"
  code=$(echo "$result" | tail -n1)
  body=$(echo "$result" | sed '$d')
  echo "$body" | jq . 2>/dev/null || echo "$body"
  case "$code" in
    2*) : ;;
    *) fail "PUT _data_stream/$DATA_STREAM returned HTTP $code (expected 2xx)" ;;
  esac
  acknowledged=$(echo "$body" | jq -r '.acknowledged // false')
  [ "$acknowledged" = true ] || fail "data stream create not acknowledged"
  echo "[setup] data stream '$DATA_STREAM' created ✓"
fi

# 3. Sync the template's mapping onto the live data stream. The template only
# shapes NEW backing indices, so a stream provisioned before a mapping change
# (e.g. the host.* fields) would keep the old strict mapping and REJECT the new
# fields — silent loss on a fail-open hook. Adding fields to a strict mapping is
# allowed and idempotent, so PUT the template's mappings to the stream every run
# to keep an already-provisioned stream forward-compatible.
echo "[setup] syncing mapping onto data stream '$DATA_STREAM'…"
mappings=$(jq -c '.template.mappings' "$TEMPLATE_FILE") || fail "could not read mappings from $TEMPLATE_FILE"
result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/$DATA_STREAM/_mapping" \
  -H 'Content-Type: application/json' --data "$mappings") || fail "request to Elasticsearch failed"
code=$(echo "$result" | tail -n1)
body=$(echo "$result" | sed '$d')
echo "$body" | jq . 2>/dev/null || echo "$body"
case "$code" in
  2*) : ;;
  *) fail "PUT $DATA_STREAM/_mapping returned HTTP $code (expected 2xx)" ;;
esac
acknowledged=$(echo "$body" | jq -r '.acknowledged // false')
[ "$acknowledged" = true ] || fail "data stream mapping update not acknowledged"
echo "[setup] mapping synced onto '$DATA_STREAM' ✓"

echo
echo "PASS: Agent Audit store '$DATA_STREAM' ready on $ES_URL (strict mapping,"
echo "30-day retention). The UserPromptSubmit hook indexes one document per"
echo "submitted prompt here, independent of the OTLP/APM pipeline."
