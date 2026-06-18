#!/usr/bin/env bash
#
# import-index-templates.sh — the Elasticsearch service's generic data-stream
# index-template applier. Each argument is a template name whose body lives at
# index-templates/<name>.json under this service component. For each, it installs
# the composable index template, creates the data stream <name>-default if absent,
# and syncs the template's mapping onto the live stream. Carries no per-backend
# selection — the calling backend passes the names its identity calls for.
#
# The mapping sync (step 3) matters because a template only shapes NEW backing
# indices: a stream provisioned before a mapping change would keep the old strict
# mapping and REJECT the new fields (silent loss on a fail-open hook). Adding
# fields to a strict mapping is allowed and idempotent, so the mapping is PUT every
# run to keep the stream forward-compatible.
#
# Idempotent: each template PUT replaces in place; each data stream is created only
# if absent (a create is not idempotent, so we check first); the mapping PUT only
# adds fields.
#
#   ES_URL=http://localhost:9200 \
#     scripts/import-index-templates.sh logs-agent_audit.user_prompt logs-agent_audit.tool_call
#
# Prerequisites: curl, jq. Run from anywhere — it locates its own component dir.

set -euo pipefail

ES_URL=${ES_URL:-http://localhost:9200}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$COMPONENT_DIR"

skip() {
  echo "SKIP: $*"
  exit 0
}
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || skip "curl not found"
command -v jq >/dev/null 2>&1 || skip "jq not found"

[ "$#" -ge 1 ] || fail "usage: import-index-templates.sh <template-name>..."

# provision <template-name>: data stream is the conventional <name>-default.
provision() {
  template=$1
  data_stream=$template-default
  template_file=index-templates/$template.json
  [ -f "$template_file" ] || fail "index template not found: $COMPONENT_DIR/$template_file"

  # 1. Install / replace the composable index template (idempotent).
  echo "[apply] installing index template '$template' on $ES_URL…"
  result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/_index_template/$template" \
    -H 'Content-Type: application/json' --data "@$template_file") || fail "request to Elasticsearch failed"
  code=$(echo "$result" | tail -n1)
  body=$(echo "$result" | sed '$d')
  echo "$body" | jq . 2>/dev/null || echo "$body"
  case "$code" in 2*) : ;; *) fail "PUT _index_template/$template returned HTTP $code (expected 2xx)" ;; esac
  [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "index template PUT not acknowledged"
  echo "[apply] index template '$template' installed ✓"

  # 2. Create the data stream if it does not already exist (PUT is not idempotent).
  existing=$(curl -s -o /dev/null -w '%{http_code}' "$ES_URL/_data_stream/$data_stream") || fail "request to Elasticsearch failed"
  if [ "$existing" = 200 ]; then
    echo "[apply] data stream '$data_stream' already exists — leaving as-is"
  else
    echo "[apply] creating data stream '$data_stream' on $ES_URL…"
    result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/_data_stream/$data_stream") || fail "request to Elasticsearch failed"
    code=$(echo "$result" | tail -n1)
    body=$(echo "$result" | sed '$d')
    echo "$body" | jq . 2>/dev/null || echo "$body"
    case "$code" in 2*) : ;; *) fail "PUT _data_stream/$data_stream returned HTTP $code (expected 2xx)" ;; esac
    [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "data stream create not acknowledged"
    echo "[apply] data stream '$data_stream' created ✓"
  fi

  # 3. Sync the template's mapping onto the live data stream (forward-compatible).
  echo "[apply] syncing mapping onto data stream '$data_stream'…"
  mappings=$(jq -c '.template.mappings' "$template_file") || fail "could not read mappings from $template_file"
  [ "$mappings" != null ] || fail "$template_file has no .template.mappings to sync"
  result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/$data_stream/_mapping" \
    -H 'Content-Type: application/json' --data "$mappings") || fail "request to Elasticsearch failed"
  code=$(echo "$result" | tail -n1)
  body=$(echo "$result" | sed '$d')
  echo "$body" | jq . 2>/dev/null || echo "$body"
  case "$code" in 2*) : ;; *) fail "PUT $data_stream/_mapping returned HTTP $code (expected 2xx)" ;; esac
  [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "data stream mapping update not acknowledged"
  echo "[apply] mapping synced onto '$data_stream' ✓"
  echo
}

for template in "$@"; do provision "$template"; done

echo "PASS: index template(s) + data stream(s) applied on $ES_URL: $*"
