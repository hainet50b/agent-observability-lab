#!/usr/bin/env bash
#
# setup-agent-audit.sh — provision the Agent Audit data streams.
#
# Direct agent-audit records (hook-captured user prompts and tool calls) live in
# dedicated Elasticsearch **log data streams**, separate from the OTLP/APM telemetry
# streams (see SPEC/agent-audit.md). Each stream is **agent-cross-cutting**: the AI
# agent (Codex CLI / Claude Code / …) is a document field (agent_audit.agent.*), not
# a segment of the data stream name — so a future codex/claude/opencode capture all
# land in the same store, keyed by that field. That is why this is **backend-owned**
# (like setup-prompt-audit.sh), not agent-owned.
#
# Two streams are provisioned from their single-source-of-truth templates:
#   * logs-agent_audit.user_prompt-default  (template agent-audit.user_prompt.template.json)
#       — one document per submitted prompt (UserPromptSubmit hook).
#   * logs-agent_audit.tool_call-default    (template agent-audit.tool_call.template.json)
#       — one document per completed tool call (PostToolUse hook).
# For each, this creates: (1) the composable index template (index_patterns
# logs-agent_audit.<dataset>-*, data_stream: {}, strict mappings, priority 200 to
# win over the built-in `logs-*-*` template, 30-day data-stream lifecycle ==
# the lab's default audit retention), and (2) the data stream itself, and (3)
# syncs the template's mapping onto the live stream.
#
# The mappings are `dynamic: strict` on purpose: a hook bug that emits an unexpected
# field fails the index rather than silently growing the audit schema. The setup
# credentials used here own template / data-stream / mapping creation; the hook's
# own write credentials should be scoped to create-only document ingestion
# (`create_doc`) on logs-agent_audit.user_prompt-* / logs-agent_audit.tool_call-*
# (see SPEC/agent-audit.md "Delivery and authorization"). The lab runs with security
# disabled, so no role/api-key is created here — the hooks index via each stream's
# `_doc` endpoint (op_type=create); the `create_doc` privilege is the production
# posture, granted by stack/admin setup, not by these end-user hook scripts.
#
# Idempotent: each template PUT replaces in place; each data stream is created only
# if absent (a create is not idempotent, so we check first); the mapping PUT only
# adds fields (idempotent on a strict mapping).
#
# Prerequisites: curl, jq. Override the Elasticsearch base URL with ES_URL if you
# publish a different port than the default below.
#
#   ES_URL=http://localhost:9200  scripts/setup-agent-audit.sh
#
# Run from anywhere — it locates its own component directory like the others.

set -euo pipefail

ES_URL=${ES_URL:-http://localhost:9200}

# Resolve and enter the component root (parent of this scripts/ directory) so the
# elasticsearch/ path resolves regardless of the caller's cwd.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$COMPONENT_DIR"

skip() { echo "SKIP: $*"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || skip "curl not found"
command -v jq   >/dev/null 2>&1 || skip "jq not found"

# provision <template-name> <data-stream> <template-file>
# Installs the index template, creates the data stream if absent, and syncs the
# template's mapping onto the live stream. Fails loudly on any non-2xx.
provision() {
  template=$1 data_stream=$2 template_file=$3

  [ -f "$template_file" ] || fail "index template not found: $COMPONENT_DIR/$template_file"

  # 1. Install / replace the composable index template (idempotent).
  echo "[setup] installing index template '$template' on $ES_URL…"
  result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/_index_template/$template" \
    -H 'Content-Type: application/json' --data "@$template_file") || fail "request to Elasticsearch failed"
  code=$(echo "$result" | tail -n1)
  body=$(echo "$result" | sed '$d')
  echo "$body" | jq . 2>/dev/null || echo "$body"
  case "$code" in 2*) : ;; *) fail "PUT _index_template/$template returned HTTP $code (expected 2xx)" ;; esac
  [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "index template PUT not acknowledged"
  echo "[setup] index template '$template' installed ✓"

  # 2. Create the data stream if it does not already exist (PUT is not idempotent).
  existing=$(curl -s -o /dev/null -w '%{http_code}' "$ES_URL/_data_stream/$data_stream") || fail "request to Elasticsearch failed"
  if [ "$existing" = 200 ]; then
    echo "[setup] data stream '$data_stream' already exists — leaving as-is"
  else
    echo "[setup] creating data stream '$data_stream' on $ES_URL…"
    result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/_data_stream/$data_stream") || fail "request to Elasticsearch failed"
    code=$(echo "$result" | tail -n1)
    body=$(echo "$result" | sed '$d')
    echo "$body" | jq . 2>/dev/null || echo "$body"
    case "$code" in 2*) : ;; *) fail "PUT _data_stream/$data_stream returned HTTP $code (expected 2xx)" ;; esac
    [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "data stream create not acknowledged"
    echo "[setup] data stream '$data_stream' created ✓"
  fi

  # 3. Sync the template's mapping onto the live data stream. The template only
  # shapes NEW backing indices, so a stream provisioned before a mapping change
  # would keep the old strict mapping and REJECT the new fields — silent loss on a
  # fail-open hook. Adding fields to a strict mapping is allowed and idempotent, so
  # PUT the template's mappings to the stream every run to keep it forward-compatible.
  echo "[setup] syncing mapping onto data stream '$data_stream'…"
  mappings=$(jq -c '.template.mappings' "$template_file") || fail "could not read mappings from $template_file"
  result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/$data_stream/_mapping" \
    -H 'Content-Type: application/json' --data "$mappings") || fail "request to Elasticsearch failed"
  code=$(echo "$result" | tail -n1)
  body=$(echo "$result" | sed '$d')
  echo "$body" | jq . 2>/dev/null || echo "$body"
  case "$code" in 2*) : ;; *) fail "PUT $data_stream/_mapping returned HTTP $code (expected 2xx)" ;; esac
  [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "data stream mapping update not acknowledged"
  echo "[setup] mapping synced onto '$data_stream' ✓"
  echo
}

provision logs-agent_audit.user_prompt logs-agent_audit.user_prompt-default \
  elasticsearch/agent-audit.user_prompt.template.json
provision logs-agent_audit.tool_call logs-agent_audit.tool_call-default \
  elasticsearch/agent-audit.tool_call.template.json

echo "PASS: Agent Audit stores ready on $ES_URL (strict mappings, 30-day retention):"
echo "  logs-agent_audit.user_prompt-default — the UserPromptSubmit hook indexes one"
echo "    document per submitted prompt here."
echo "  logs-agent_audit.tool_call-default   — the PostToolUse hook indexes one"
echo "    document per completed tool call here."
echo "Both are independent of the OTLP/APM pipeline."
