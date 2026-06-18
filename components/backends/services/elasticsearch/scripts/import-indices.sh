#!/usr/bin/env bash
#
# import-indices.sh — the Elasticsearch service's generic concrete-index applier.
# Each argument is an index name whose mapping lives at indices/<name>.json under
# this service component; the index is created from it if it does not already
# exist. Carries no per-backend selection — the calling backend passes the names
# its identity calls for.
#
# Idempotent: a create-index PUT is NOT idempotent, so an existing index is left
# untouched (we check first rather than blindly PUT).
#
#   ES_URL=http://localhost:9200  scripts/import-indices.sh prompts-audit
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

[ "$#" -ge 1 ] || fail "usage: import-indices.sh <index-name>..."

apply() {
  name=$1
  file=indices/$name.json
  [ -f "$file" ] || fail "index mapping not found: $COMPONENT_DIR/$file"

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

  case "$code" in
  2*) : ;;
  *) fail "PUT /$name returned HTTP $code (expected 2xx)" ;;
  esac
  [ "$(echo "$body" | jq -r '.acknowledged // false')" = true ] || fail "index create not acknowledged"
  echo "[apply] index '$name' created ✓"
}

for name in "$@"; do apply "$name"; done

echo
echo "PASS: index/indices applied on $ES_URL: $*"
