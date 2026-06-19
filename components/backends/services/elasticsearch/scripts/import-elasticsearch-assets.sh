#!/usr/bin/env bash
# Applies the Elasticsearch assets for each CONCERN arg (a dir under this component).
# Files are typed by suffix: *.pipeline.json → ingest pipeline, *.template.json →
# index template + <name>-default data stream + mapping sync, *.index.json → index.
# Idempotent: PUTs replace; streams/indices created only if absent; a template's
# mapping is re-synced each run (a strict mapping still accepts added fields). Needs curl, jq.

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

[ "$#" -ge 1 ] || fail "usage: import-elasticsearch-assets.sh <concern>... (e.g. shared codex-cli)"

apply_pipeline() {
  name=$1 file=$2
  echo "[apply] ingest pipeline '$name' on $ES_URL…"
  result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/_ingest/pipeline/$name" \
    -H 'Content-Type: application/json' --data "@$file") || fail "request to Elasticsearch failed"
  code=$(echo "$result" | tail -n1)
  body=$(echo "$result" | sed '$d')
  echo "$body" | jq . 2>/dev/null || echo "$body"
  case "$code" in 2*) : ;; *) fail "PUT _ingest/pipeline/$name returned HTTP $code (expected 2xx)" ;; esac
  [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "pipeline PUT not acknowledged"
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
  echo "$body" | jq . 2>/dev/null || echo "$body"
  case "$code" in 2*) : ;; *) fail "PUT _index_template/$template returned HTTP $code (expected 2xx)" ;; esac
  [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "index template PUT not acknowledged"
  echo "[apply] index template '$template' installed ✓"

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
  echo "$body" | jq . 2>/dev/null || echo "$body"
  case "$code" in 2*) : ;; *) fail "PUT /$name returned HTTP $code (expected 2xx)" ;; esac
  [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "index create not acknowledged"
  echo "[apply] index '$name' created ✓"
}

# pipelines, then templates, then indices; a concern need not ship all three.
import_concern() {
  concern=$1
  [ -d "$concern" ] || fail "concern dir not found: $COMPONENT_DIR/$concern"
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
