#!/usr/bin/env bash
#
# smoke-test.sh — claude-code-elastic end-to-end pipeline smoke / verification.
#
# Follows the 3A pattern (see CONVENTIONS.md):
#
#   Arrange — bring the stack up and wait for Elasticsearch, Kibana, and APM
#             Server to all report healthy.
#   Act     — POST a synthetic OTLP/protobuf metrics payload and a synthetic
#             OTLP/protobuf logs payload to the APM Server OTLP/HTTP endpoint,
#             shaped like the two channels Claude Code emits (one metric data
#             point + one log/event record), tagged with service.name
#             "cce-smoke-test". This stack's APM Server always protobuf-decodes
#             the request body (it ignores Content-Type and has no OTLP/JSON
#             toggle), so the probe sends protobuf — matching real Claude Code,
#             which exports http/protobuf.
#   Assert  — query Elasticsearch and confirm those documents were ingested into
#             the APM data streams, proving the OTLP -> APM Server ->
#             Elasticsearch path that Claude Code relies on works end to end.
#
# It then prints a DISCOVER summary: the service.name values currently present
# in the APM metrics/logs data streams, so real Claude Code telemetry (from an
# actual `claude` session — see ../README.md, Quick Tour step 2) shows up
# alongside the probe.
#
# Why synthetic telemetry: the Act step must be self-contained and deterministic
# (no API key, no interactive session) so it can run as a gate. Real Claude Code
# telemetry lands under its own service name(s) through the identical pipeline.
#
# Expected indices / fields are documented in ../README.md (telemetry notes).
#
# Prerequisites: docker (+ a running daemon), curl, jq, base64 (coreutils). If
# the daemon is not reachable the script SKIPs (exit 0) rather than failing —
# there is nothing to smoke-test without it. No protobuf tooling is needed: the
# two OTLP payloads are precomputed and embedded as base64 below.
#
# Endpoints can be overridden via ES_URL / APM_OTLP_URL if you publish different
# ports than the defaults below.

set -euo pipefail

ES_URL=${ES_URL:-http://localhost:9200}
APM_OTLP_URL=${APM_OTLP_URL:-http://localhost:8200}
SERVICE_NAME=cce-smoke-test

# Resolve and enter the stack root (parent of this scripts/ directory) so
# `docker compose` finds docker-compose.yml regardless of the caller's cwd.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STACK_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$STACK_DIR"

skip() { echo "SKIP: $*"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Preconditions ---------------------------------------------------------
command -v docker >/dev/null 2>&1 || skip "docker CLI not found"
command -v curl   >/dev/null 2>&1 || skip "curl not found"
command -v jq     >/dev/null 2>&1 || skip "jq not found"
command -v base64 >/dev/null 2>&1 || skip "base64 not found"
docker info >/dev/null 2>&1        || skip "docker daemon not reachable; nothing to smoke-test"

# --- Arrange ---------------------------------------------------------------
echo "[arrange] bringing the stack up (docker compose up -d)…"
docker compose up -d

wait_healthy() {
  cname=$1 tries=${2:-60}
  for _ in $(seq 1 "$tries"); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "$cname" 2>/dev/null || echo "")
    [ "$status" = healthy ] && { echo "[arrange] $cname healthy"; return 0; }
    sleep 5
  done
  return 1
}
for c in cce-elasticsearch cce-kibana cce-apm-server; do
  wait_healthy "$c" 60 || { docker compose ps; fail "$c did not become healthy"; }
done

# --- Act -------------------------------------------------------------------
echo "[act] sending synthetic OTLP/protobuf telemetry (service.name=$SERVICE_NAME)…"

# This stack's APM Server always protobuf-decodes the OTLP body (it ignores
# Content-Type and exposes no OTLP/JSON toggle), so the probe POSTs protobuf —
# the same wire format real Claude Code uses (http/protobuf). The two payloads
# are precomputed and embedded as base64 to avoid pulling in protobuf tooling:
#   - metrics: ExportMetricsServiceRequest, one cce.smoke.counter sum point
#   - logs:    ExportLogsServiceRequest,    one cce.smoke.event log record
# Both bake service.name=cce-smoke-test and a fixed timeUnixNano (≈2026-05-28);
# the assertions below query _count by service.name with no time filter, so the
# fixed timestamp does not affect them.
metrics_payload="ClUKIgogCgxzZXJ2aWNlLm5hbWUSEAoOY2NlLXNtb2tlLXRlc3QSLxItChFjY2Uuc21va2UuY291bnRlcjoYChIZAAAytJHUsxgxAQAAAAAAAAAQAhgB"
logs_payload="CmcKIgogCgxzZXJ2aWNlLm5hbWUSEAoOY2NlLXNtb2tlLXRlc3QSQRI/CQAAMrSR1LMYEAkqEQoPY2NlIHNtb2tlIGV2ZW50Mh8KCmV2ZW50Lm5hbWUSEQoPY2NlLnNtb2tlLmV2ZW50"

post_otlp() {
  path=$1 b64=$2
  code=$(printf '%s' "$b64" | base64 -d | curl -s -o /dev/null -w '%{http_code}' \
    -X POST "$APM_OTLP_URL$path" \
    -H 'Content-Type: application/x-protobuf' \
    --data-binary @-)
  [ "$code" = 200 ] || fail "OTLP POST $path returned HTTP $code (expected 200)"
  echo "[act] OTLP POST $path -> HTTP $code"
}

post_otlp /v1/metrics "$metrics_payload"
post_otlp /v1/logs    "$logs_payload"

# --- Assert ----------------------------------------------------------------
es_count() {
  idx=$1
  curl -s "$ES_URL/$idx/_count?ignore_unavailable=true&allow_no_indices=true" \
    -H 'Content-Type: application/json' \
    --data "{\"query\":{\"term\":{\"service.name\":\"$SERVICE_NAME\"}}}" \
    | jq -r '.count // 0'
}

assert_landed() {
  label=$1 idx=$2
  for _ in $(seq 1 30); do
    n=$(es_count "$idx")
    if [ "${n:-0}" -ge 1 ]; then
      echo "[assert] $label: $n document(s) in '$idx' for service.name=$SERVICE_NAME ✓"
      return 0
    fi
    sleep 2
  done
  fail "no $label documents landed in '$idx' within timeout"
}

echo "[assert] querying Elasticsearch for the synthetic documents…"
assert_landed "metrics" "metrics-apm*"
assert_landed "events"  "logs-apm*"

# --- Discover (informational, never fails) ---------------------------------
discover() {
  idx=$1
  curl -s "$ES_URL/$idx/_search?ignore_unavailable=true&allow_no_indices=true" \
    -H 'Content-Type: application/json' \
    --data '{"size":0,"aggs":{"svc":{"terms":{"field":"service.name","size":50}}}}' \
    | jq -r '.aggregations.svc.buckets[]? | "    \(.key)  (\(.doc_count) docs)"'
}
echo "[discover] service.name values currently in the APM data streams:"
echo "  metrics-apm*:"
discover "metrics-apm*"
echo "  logs-apm*:"
discover "logs-apm*"

echo
echo "PASS: OTLP -> APM Server -> Elasticsearch pipeline verified."
echo "Run a real Claude Code session (see ../README.md, Quick Tour step 2) to populate the"
echo "claude-code service streams, then inspect them in Kibana (http://localhost:5601)."
