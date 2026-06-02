#!/usr/bin/env bash
#
# setup-trace-routing.sh — physically isolate Claude Code's trace spans.
#
# APM Server writes every OTLP span to the service-agnostic `traces-apm-default`
# data stream (unlike the metrics/events streams, whose dataset embeds the
# service), so spans from all producers co-mingle and a data view can't store a
# `service.name` filter to separate them. This installs the sanctioned routing
# hook: a `reroute` processor in the **`traces-apm@custom`** ingest pipeline,
# which `traces-apm@default-pipeline` already calls with
# `ignore_missing_pipeline: true`. Docs whose `service.name` is `claude-code`
# are rerouted into the dedicated **`traces-apm-claudecode`** data stream — it
# still matches the `traces-apm-*` index template, so it inherits the full APM
# trace mappings; other producers stay in `traces-apm-default`. Rerouting to the
# same namespace is a no-op, so there is no pipeline loop.
#
# The traces data view (kibana/claude-code-data-views.ndjson, id
# `cce-claude-code-traces`) is scoped to `traces-apm-claudecode*`, so it needs no
# `service.name` filter once this pipeline is installed. Spans captured before
# the pipeline existed stay in `traces-apm-default`; that is expected.
#
# Idempotent: a PUT replaces the pipeline definition, so re-running is safe.
#
# Prerequisites: curl, jq. Override the Elasticsearch base URL with ES_URL if you
# publish a different port than the default below.
#
#   ES_URL=http://localhost:9200  scripts/setup-trace-routing.sh
#
# Run from anywhere — it locates its own stack directory like smoke-test.sh.

set -euo pipefail

ES_URL=${ES_URL:-http://localhost:9200}
PIPELINE=traces-apm@custom

# Resolve and enter the stack root (parent of this scripts/ directory), matching
# smoke-test.sh, so behaviour is consistent regardless of the caller's cwd.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STACK_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$STACK_DIR"

skip() { echo "SKIP: $*"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || skip "curl not found"
command -v jq   >/dev/null 2>&1 || skip "jq not found"

# A reroute that fires only on Claude Code spans; other producers fall through
# unchanged and stay in traces-apm-default.
read -r -d '' BODY <<'JSON' || true
{
  "description": "claude-code-elastic: route service.name=claude-code trace spans to traces-apm-claudecode",
  "processors": [
    { "reroute": { "if": "ctx.service?.name == 'claude-code'", "namespace": "claudecode" } }
  ]
}
JSON

echo "[setup] installing ingest pipeline '$PIPELINE' on $ES_URL…"
result=$(curl -s -w '\n%{http_code}' -X PUT "$ES_URL/_ingest/pipeline/$PIPELINE" \
  -H 'Content-Type: application/json' --data "$BODY") || fail "request to Elasticsearch failed"

code=$(echo "$result" | tail -n1)
body=$(echo "$result" | sed '$d')

echo "$body" | jq . 2>/dev/null || echo "$body"

case "$code" in
  2*) : ;;
  *) fail "PUT _ingest/pipeline/$PIPELINE returned HTTP $code (expected 2xx)" ;;
esac

acknowledged=$(echo "$body" | jq -r '.acknowledged // false')
[ "$acknowledged" = true ] || fail "pipeline PUT not acknowledged"

echo "[setup] pipeline '$PIPELINE' installed ✓"
echo
echo "PASS: Claude Code trace spans (service.name=claude-code) now route to"
echo "'traces-apm-claudecode'. Enable tracing on a session (see ../README.md,"
echo "Quick Tour step 2) and open the Claude Code — Traces data view in Discover."
