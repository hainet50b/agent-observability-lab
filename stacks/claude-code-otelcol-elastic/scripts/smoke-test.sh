#!/usr/bin/env bash
#
# smoke-test.sh — claude-code-otelcol-elastic end-to-end pipeline smoke / verification.
#
# Same 3A shape as claude-code-elastic's smoke test, but the probe is POSTed to
# the local OpenTelemetry Collector instead of the APM Server directly — proving
# the full sidecar path agent → Collector → APM Server → Elasticsearch:
#
#   Arrange — bring the stack up and wait for Elasticsearch, Kibana, and APM
#             Server to report healthy, then wait for the Collector to accept
#             OTLP on its HTTP port (the contrib image is distroless and carries
#             no healthcheck, so readiness is polled from the host with curl).
#   Act     — POST a synthetic OTLP/protobuf metrics payload, a logs payload, and
#             a traces payload to the Collector's OTLP/HTTP endpoint (:4318),
#             shaped like the three channels Claude Code emits (one metric data
#             point + one log/event record + one trace span), tagged with
#             service.name "aol-smoke-test". The Collector forwards them over
#             OTLP/HTTP to the APM Server, which protobuf-decodes the body — the
#             same wire format real Claude Code uses (http/protobuf).
#   Assert  — query Elasticsearch and confirm those documents were ingested into
#             the APM data streams, proving the agent → Collector → APM Server →
#             Elasticsearch path works end to end.
#
# It then prints a DISCOVER summary: the service.name values currently present
# in the APM metrics/logs/traces data streams, so real Claude Code telemetry
# (from an actual `claude` session pointed at the Collector — see ../README.md,
# Quick Tour step 2) shows up alongside the probe.
#
# Why synthetic telemetry: the Act step must be self-contained and deterministic
# (no API key, no interactive session) so it can run as a gate. Real Claude Code
# telemetry lands under its own service name(s) through the identical pipeline.
#
# Expected indices / fields are documented in ../README.md.
#
# Prerequisites: docker (+ a running daemon), curl, jq, base64 (coreutils). If
# the daemon is not reachable the script SKIPs (exit 0) rather than failing —
# there is nothing to smoke-test without it. No protobuf tooling is needed: the
# three OTLP payloads are precomputed and embedded as base64 below.
#
# Endpoints can be overridden via ES_URL / OTEL_COLLECTOR_URL if you publish
# different ports than the defaults below.

set -euo pipefail

ES_URL=${ES_URL:-http://localhost:9200}
OTEL_COLLECTOR_URL=${OTEL_COLLECTOR_URL:-http://localhost:4318}
SERVICE_NAME=aol-smoke-test

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
for c in aol-elasticsearch aol-kibana aol-apm-server; do
  wait_healthy "$c" 60 || { docker compose ps; fail "$c did not become healthy"; }
done

# The Collector (contrib image) ships no healthcheck — poll its OTLP/HTTP port
# from the host instead. A bare GET to the OTLP receiver returns an HTTP status
# (404/405) once it is listening, so curl exiting 0 means the port is accepting
# connections (curl only exits non-zero here on connection refused).
wait_collector() {
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null "$OTEL_COLLECTOR_URL/" 2>/dev/null; then
      echo "[arrange] otel-collector accepting OTLP on $OTEL_COLLECTOR_URL"
      return 0
    fi
    sleep 2
  done
  return 1
}
wait_collector || { docker compose ps; fail "otel-collector did not start accepting connections"; }

# --- Act -------------------------------------------------------------------
echo "[act] sending synthetic OTLP/protobuf telemetry via the Collector (service.name=$SERVICE_NAME)…"

# The probe POSTs protobuf to the Collector, which forwards it to the APM Server
# (which always protobuf-decodes the OTLP body) — the same wire format real
# Claude Code uses (http/protobuf). The three payloads are precomputed and
# embedded as base64 to avoid pulling in protobuf tooling:
#   - metrics: ExportMetricsServiceRequest, one aol.smoke.counter sum point
#   - logs:    ExportLogsServiceRequest,    one aol.smoke.event log record
#   - traces:  ExportTraceServiceRequest,   one aol.smoke.span span
# All three bake service.name=aol-smoke-test and a fixed timeUnixNano (≈2026-05-28);
# the assertions below query _count by service.name with no time filter, so the
# fixed timestamp does not affect them.
metrics_payload="ClUKIgogCgxzZXJ2aWNlLm5hbWUSEAoOYW9sLXNtb2tlLXRlc3QSLxItChFhb2wuc21va2UuY291bnRlcjoYChIZAAAytJHUsxgxAQAAAAAAAAAQAhgB"
logs_payload="CmcKIgogCgxzZXJ2aWNlLm5hbWUSEAoOYW9sLXNtb2tlLXRlc3QSQRI/CQAAMrSR1LMYEAkqEQoPYW9sIHNtb2tlIGV2ZW50Mh8KCmV2ZW50Lm5hbWUSEQoPYW9sLnNtb2tlLmV2ZW50"
traces_payload="CmgKIgogCgxzZXJ2aWNlLm5hbWUSEAoOYW9sLXNtb2tlLXRlc3QSQhJAChAREREREREREREREREREREREggiIiIiIiIiIioOYW9sLnNtb2tlLnNwYW4wATkAADK0kdSzGEFAQkG0kdSzGA=="

post_otlp() {
  path=$1 b64=$2
  code=$(printf '%s' "$b64" | base64 -d | curl -s -o /dev/null -w '%{http_code}' \
    -X POST "$OTEL_COLLECTOR_URL$path" \
    -H 'Content-Type: application/x-protobuf' \
    --data-binary @-)
  [ "$code" = 200 ] || fail "OTLP POST $path returned HTTP $code (expected 200)"
  echo "[act] OTLP POST $path -> HTTP $code"
}

post_otlp /v1/metrics "$metrics_payload"
post_otlp /v1/logs    "$logs_payload"
post_otlp /v1/traces  "$traces_payload"

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
assert_landed "traces"  "traces-apm*"

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
echo "  traces-apm*:"
discover "traces-apm*"

echo
echo "PASS: Claude Code → Collector → APM Server → Elasticsearch pipeline verified."
echo "Run a real Claude Code session pointed at the Collector (see ../README.md, Quick Tour"
echo "step 2) to populate the claude-code service streams, then inspect them in Kibana"
echo "(http://localhost:5601)."
