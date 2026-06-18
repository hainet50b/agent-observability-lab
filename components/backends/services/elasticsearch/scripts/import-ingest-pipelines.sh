#!/usr/bin/env bash
#
# import-ingest-pipelines.sh — the Elasticsearch service's generic ingest-pipeline
# applier. Each argument is a pipeline name whose body lives at
# ingest-pipelines/<name>.json under this service component; it is PUT verbatim to
# _ingest/pipeline/<name>. Carries no per-backend selection — the calling backend
# passes the names its identity calls for; the per-pipeline rationale lives in each
# JSON body's "description".
#
# Idempotent: a PUT replaces the pipeline definition, so re-running is safe.
#
#   ES_URL=http://localhost:9200 \
#     scripts/import-ingest-pipelines.sh traces-apm@custom logs-apm.app@custom
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

[ "$#" -ge 1 ] || fail "usage: import-ingest-pipelines.sh <pipeline-name>..."

apply() {
  name=$1
  file=ingest-pipelines/$name.json
  [ -f "$file" ] || fail "pipeline body not found: $COMPONENT_DIR/$file"

  echo "[apply] ingest pipeline '$name' on $ES_URL…"
  result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/_ingest/pipeline/$name" \
    -H 'Content-Type: application/json' --data "@$file") || fail "request to Elasticsearch failed"

  code=$(echo "$result" | tail -n1)
  body=$(echo "$result" | sed '$d')
  echo "$body" | jq . 2>/dev/null || echo "$body"

  case "$code" in
  2*) : ;;
  *) fail "PUT _ingest/pipeline/$name returned HTTP $code (expected 2xx)" ;;
  esac
  [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "pipeline PUT not acknowledged"
  echo "[apply] ingest pipeline '$name' installed ✓"
}

for name in "$@"; do apply "$name"; done

echo
echo "PASS: ingest pipeline(s) applied on $ES_URL: $*"
