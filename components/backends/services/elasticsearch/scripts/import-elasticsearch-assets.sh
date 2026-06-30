#!/usr/bin/env bash
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

[ "$#" -ge 1 ] || fail "usage: import-elasticsearch-assets.sh <concern>... (e.g. shared codex)"

apply_ilm() {
  name=$1 file=$2
  echo "[apply] ILM policy '$name' on $ES_URL…"
  result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/_ilm/policy/$name" \
    -H 'Content-Type: application/json' --data "@$file") || fail "request to Elasticsearch failed"
  code=$(echo "$result" | tail -n1)
  body=$(echo "$result" | sed '$d')
  case "$code" in 2*) : ;; *) fail "PUT _ilm/policy/$name returned HTTP $code (expected 2xx): $(echo "$body" | jq -r '.error.reason // .' 2>/dev/null || echo "$body")" ;; esac
  [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "ILM policy PUT not acknowledged: $body"
  echo "[apply] ILM policy '$name' installed ✓"
}

apply_component_template() {
  name=$1 file=$2
  echo "[apply] component template '$name' on $ES_URL…"
  result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/_component_template/$name" \
    -H 'Content-Type: application/json' --data "@$file") || fail "request to Elasticsearch failed"
  code=$(echo "$result" | tail -n1)
  body=$(echo "$result" | sed '$d')
  case "$code" in 2*) : ;; *) fail "PUT _component_template/$name returned HTTP $code (expected 2xx): $(echo "$body" | jq -r '.error.reason // .' 2>/dev/null || echo "$body")" ;; esac
  [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "component template PUT not acknowledged: $body"
  echo "[apply] component template '$name' installed ✓"
}

apply_pipeline() {
  name=$1 file=$2
  echo "[apply] ingest pipeline '$name' on $ES_URL…"
  result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/_ingest/pipeline/$name" \
    -H 'Content-Type: application/json' --data "@$file") || fail "request to Elasticsearch failed"
  code=$(echo "$result" | tail -n1)
  body=$(echo "$result" | sed '$d')
  case "$code" in 2*) : ;; *) fail "PUT _ingest/pipeline/$name returned HTTP $code (expected 2xx): $(echo "$body" | jq -r '.error.reason // .' 2>/dev/null || echo "$body")" ;; esac
  [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "pipeline PUT not acknowledged: $body"
  echo "[apply] ingest pipeline '$name' installed ✓"
}

apply_template() {
  template=$1 template_file=$2
  data_stream=$template-default

  echo "[apply] installing index template '$template' on $ES_URL…"
  result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/_index_template/$template" \
    -H 'Content-Type: application/json' --data "@$template_file") || fail "request to Elasticsearch failed"
  code=$(echo "$result" | tail -n1)
  body=$(echo "$result" | sed '$d')
  case "$code" in 2*) : ;; *) fail "PUT _index_template/$template returned HTTP $code (expected 2xx): $(echo "$body" | jq -r '.error.reason // .' 2>/dev/null || echo "$body")" ;; esac
  [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "index template PUT not acknowledged: $body"
  echo "[apply] index template '$template' installed ✓"

  existing=$(curl -s -o /dev/null -w '%{http_code}' "$ES_URL/_data_stream/$data_stream") || fail "request to Elasticsearch failed"
  if [ "$existing" = 200 ]; then
    echo "[apply] data stream '$data_stream' already exists — leaving as-is"
  else
    echo "[apply] creating data stream '$data_stream' on $ES_URL…"
    result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/_data_stream/$data_stream") || fail "request to Elasticsearch failed"
    code=$(echo "$result" | tail -n1)
    body=$(echo "$result" | sed '$d')
    case "$code" in 2*) : ;; *) fail "PUT _data_stream/$data_stream returned HTTP $code (expected 2xx): $(echo "$body" | jq -r '.error.reason // .' 2>/dev/null || echo "$body")" ;; esac
    [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "data stream create not acknowledged: $body"
    echo "[apply] data stream '$data_stream' created ✓"
  fi

  echo "[apply] syncing mapping onto data stream '$data_stream'…"
  simulated=$(curl -s -w '\n%{http_code}' -X POST "$ES_URL/_index_template/_simulate_index/$data_stream") || fail "request to Elasticsearch failed"
  code=$(echo "$simulated" | tail -n1)
  sim_body=$(echo "$simulated" | sed '$d')
  case "$code" in 2*) : ;; *) fail "POST _simulate_index/$data_stream returned HTTP $code (expected 2xx): $(echo "$sim_body" | jq -r '.error.reason // .' 2>/dev/null || echo "$sim_body")" ;; esac
  mappings=$(echo "$sim_body" | jq -c '.template.mappings')
  [ -n "$mappings" ] && [ "$mappings" != null ] || fail "resolved composed mapping for $template has no .template.mappings"
  result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/$data_stream/_mapping" \
    -H 'Content-Type: application/json' --data "$mappings") || fail "request to Elasticsearch failed"
  code=$(echo "$result" | tail -n1)
  body=$(echo "$result" | sed '$d')
  case "$code" in 2*) : ;; *) fail "PUT $data_stream/_mapping returned HTTP $code (expected 2xx): $(echo "$body" | jq -r '.error.reason // .' 2>/dev/null || echo "$body")" ;; esac
  [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "data stream mapping update not acknowledged: $body"
  echo "[apply] mapping synced onto '$data_stream' ✓"
}

apply_index_template() {
  name=$1 file=$2
  echo "[apply] index template (overlay) '$name' on $ES_URL…"
  result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/_index_template/$name" \
    -H 'Content-Type: application/json' --data "@$file") || fail "request to Elasticsearch failed"
  code=$(echo "$result" | tail -n1)
  body=$(echo "$result" | sed '$d')
  case "$code" in 2*) : ;; *) fail "PUT _index_template/$name returned HTTP $code (expected 2xx): $(echo "$body" | jq -r '.error.reason // .' 2>/dev/null || echo "$body")" ;; esac
  [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "index template PUT not acknowledged: $body"
  echo "[apply] index template (overlay) '$name' installed ✓"
}

apply_index() {
  name=$1 file=$2
  existing=$(curl -s -o /dev/null -w '%{http_code}' "$ES_URL/$name") || fail "request to Elasticsearch failed"
  if [ "$existing" = 200 ]; then
    echo "[apply] index '$name' already exists — leaving as-is"
    return
  fi
  echo "[apply] creating index '$name' on $ES_URL…"
  result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/$name" \
    -H 'Content-Type: application/json' --data "@$file") || fail "request to Elasticsearch failed"
  code=$(echo "$result" | tail -n1)
  body=$(echo "$result" | sed '$d')
  case "$code" in 2*) : ;; *) fail "PUT /$name returned HTTP $code (expected 2xx): $(echo "$body" | jq -r '.error.reason // .' 2>/dev/null || echo "$body")" ;; esac
  [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "index create not acknowledged: $body"
  echo "[apply] index '$name' created ✓"
}

# ilm → component → pipelines → templates → index-templates → indices, so composed/referenced objects exist first
import_concern() {
  concern=$1
  [ -d "$concern" ] || fail "concern dir not found: $COMPONENT_DIR/$concern"
  for f in "$concern"/*.ilm.json; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    apply_ilm "${base%.ilm.json}" "$f"
  done
  for f in "$concern"/*.component.json; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    apply_component_template "${base%.component.json}" "$f"
  done
  for f in "$concern"/*.pipeline.json; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    apply_pipeline "${base%.pipeline.json}" "$f"
  done
  for f in "$concern"/*.template.json; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    apply_template "${base%.template.json}" "$f"
  done
  for f in "$concern"/*.index-template.json; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    apply_index_template "${base%.index-template.json}" "$f"
  done
  for f in "$concern"/*.index.json; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    apply_index "${base%.index.json}" "$f"
  done
}

echo "[import] applying Elasticsearch assets to $ES_URL…"
for concern in "$@"; do
  echo
  echo "[import] concern: $concern"
  import_concern "$concern"
done

echo
echo "PASS: Elasticsearch assets applied on $ES_URL (concerns: $*)."
