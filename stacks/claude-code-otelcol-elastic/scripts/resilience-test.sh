#!/usr/bin/env bash
#
# resilience-test.sh — claude-code-otelcol-elastic durable-queue / outage check.
#
# Phase 3b is the reason the sidecar exists (see ../README.md, "Durable queue"):
# when the link to the central backend is down, the agent keeps working against
# the always-reachable local Collector, which PERSISTS undelivered telemetry to
# disk (file_storage-backed sending_queue) and drains it on recovery — no loss.
#
# This is the 3A check for that property, and it is deliberately stronger than a
# plain stop/start: it also RESTARTS the Collector while the backend is down, so
# a pure in-memory queue would drop the probe — only an on-disk queue survives.
#
#   Arrange — bring the stack up and wait for Elasticsearch, Kibana, and APM
#             Server healthy, then for the Collector to accept OTLP. Record the
#             baseline count of the probe's unique service.name in ES.
#   Act     — simulate a central-backend outage and prove durability:
#               1. `docker compose stop apm-server`  (backend unreachable)
#               2. POST a uniquely-tagged OTLP/protobuf probe to the Collector —
#                  it is accepted (HTTP 200) and queued, not lost.
#               3. wait for the batch to flush into the on-disk queue, then
#                  `docker compose restart otel-collector` — an in-memory queue
#                  would lose the probe here; the file_storage queue does not.
#               4. `docker compose start apm-server` and wait for it healthy.
#   Assert  — the probe doc LANDS in ES after recovery (count rises above the
#             baseline) — proving it was buffered on disk through both the outage
#             and a Collector restart, then drained on reconnect. Fails if it
#             never lands.
#
# Why synthetic telemetry: the Act step must be self-contained and deterministic
# (no API key, no interactive session) so it can run as a gate. The probe carries
# a unique service.name (cce-resilience-test) so it never collides with the
# smoke-test probe or real Claude Code telemetry.
#
# Prerequisites: docker (+ a running daemon), curl, jq, base64 (coreutils). If
# the daemon is not reachable the script SKIPs (exit 0). No protobuf tooling is
# needed: the OTLP payload is precomputed and embedded as base64 below.
#
# Endpoints can be overridden via ES_URL / OTEL_COLLECTOR_URL.

set -euo pipefail

ES_URL=${ES_URL:-http://localhost:9200}
OTEL_COLLECTOR_URL=${OTEL_COLLECTOR_URL:-http://localhost:4318}
SERVICE_NAME=cce-resilience-test

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
docker info >/dev/null 2>&1        || skip "docker daemon not reachable; nothing to test"

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

# The Collector (contrib image) ships no healthcheck — poll its OTLP/HTTP port
# from the host. A bare GET returns an HTTP status once it is listening, so curl
# exiting 0 means the port is accepting connections.
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

es_count() {
  curl -s "$ES_URL/logs-apm*/_count?ignore_unavailable=true&allow_no_indices=true" \
    -H 'Content-Type: application/json' \
    --data "{\"query\":{\"term\":{\"service.name\":\"$SERVICE_NAME\"}}}" \
    | jq -r '.count // 0'
}

baseline=$(es_count)
echo "[arrange] baseline: $baseline doc(s) in 'logs-apm*' for service.name=$SERVICE_NAME"

# --- Act -------------------------------------------------------------------
# A single OTLP/protobuf logs probe (ExportLogsServiceRequest, one
# cce.resilience.event record) tagged service.name=cce-resilience-test, with a
# fixed timeUnixNano (≈2026) — the assertion counts by service.name with no time
# filter, so the fixed timestamp does not matter. Precomputed/base64-embedded to
# avoid any protobuf tooling, exactly like smoke-test.sh.
probe_payload="CnYKJwolCgxzZXJ2aWNlLm5hbWUSFQoTY2NlLXJlc2lsaWVuY2UtdGVzdBJLEkkJAAAytJHUsxgQCSoWChRjY2UgcmVzaWxpZW5jZSBldmVudDIkCgpldmVudC5uYW1lEhYKFGNjZS5yZXNpbGllbmNlLmV2ZW50"

echo "[act] 1/4 stopping apm-server to simulate a central-backend outage…"
docker compose stop apm-server

echo "[act] 2/4 POSTing the probe to the Collector (service.name=$SERVICE_NAME) while the backend is down…"
code=$(printf '%s' "$probe_payload" | base64 -d | curl -s -o /dev/null -w '%{http_code}' \
  -X POST "$OTEL_COLLECTOR_URL/v1/logs" \
  -H 'Content-Type: application/x-protobuf' \
  --data-binary @-)
[ "$code" = 200 ] || fail "Collector rejected the probe during the outage: HTTP $code (expected 200 — it should accept and queue)"
echo "[act] Collector accepted and queued the probe -> HTTP $code"

# Let the batch processor flush the probe out to the on-disk sending_queue
# before we restart (the batch buffer is in-memory; the queue is not).
echo "[act] 3/4 waiting for the batch to flush to disk, then restarting otel-collector…"
sleep 8
docker compose restart otel-collector
wait_collector || { docker compose ps; fail "otel-collector did not come back after restart"; }

# Sanity: with the backend still down, nothing can have reached ES yet.
mid=$(es_count)
[ "${mid:-0}" -le "${baseline:-0}" ] || fail "probe reached ES while apm-server was stopped (count $mid > baseline $baseline) — outage not actually simulated"
echo "[act] confirmed: probe not in ES during the outage (count still $mid)"

echo "[act] 4/4 starting apm-server and waiting for it to recover…"
docker compose start apm-server
wait_healthy cce-apm-server 60 || { docker compose ps; fail "apm-server did not become healthy after restart"; }

# --- Assert ----------------------------------------------------------------
echo "[assert] waiting for the queued probe to drain into Elasticsearch…"
for _ in $(seq 1 60); do
  n=$(es_count)
  if [ "${n:-0}" -gt "${baseline:-0}" ]; then
    echo "[assert] probe drained: $n doc(s) now in 'logs-apm*' for service.name=$SERVICE_NAME (baseline was $baseline) ✓"
    echo
    echo "PASS: telemetry sent during a backend outage survived a Collector restart and"
    echo "drained into Elasticsearch on reconnect — the durable on-disk queue works."
    exit 0
  fi
  sleep 3
done
fail "probe never landed in ES within timeout — the durable queue did not drain after recovery"
