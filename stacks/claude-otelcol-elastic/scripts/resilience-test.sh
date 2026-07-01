#!/usr/bin/env bash
set -euo pipefail

ES_URL=${ES_URL:-http://localhost:9200}
OTEL_COLLECTOR_URL=${OTEL_COLLECTOR_URL:-http://localhost:4318}
SERVICE_NAME=aol-resilience-test

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
STACK_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$STACK_DIR"

skip() {
  echo "SKIP: $*"
  exit 0
}
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || skip "docker CLI not found"
command -v curl >/dev/null 2>&1 || skip "curl not found"
command -v jq >/dev/null 2>&1 || skip "jq not found"
command -v base64 >/dev/null 2>&1 || skip "base64 not found"
docker info >/dev/null 2>&1 || skip "docker daemon not reachable; nothing to test"

echo "[arrange] bringing the stack up (docker compose up -d)…"
docker compose up -d

wait_healthy() {
  cname=$1 tries=${2:-60}
  for _ in $(seq 1 "$tries"); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "$cname" 2>/dev/null || echo "")
    [ "$status" = healthy ] && {
      echo "[arrange] $cname healthy"
      return 0
    }
    sleep 5
  done
  return 1
}
for c in aol-elasticsearch aol-kibana aol-apm-server; do
  wait_healthy "$c" 60 || {
    docker compose ps
    fail "$c did not become healthy"
  }
done

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
wait_collector || {
  docker compose ps
  fail "otel-collector did not start accepting connections"
}

es_count() {
  curl -s "$ES_URL/logs-apm*/_count?ignore_unavailable=true&allow_no_indices=true" \
    -H 'Content-Type: application/json' \
    --data "{\"query\":{\"term\":{\"service.name\":\"$SERVICE_NAME\"}}}" |
    jq -r '.count // 0'
}

baseline=$(es_count)
echo "[arrange] baseline: $baseline doc(s) in 'logs-apm*' for service.name=$SERVICE_NAME"

probe_payload="CnYKJwolCgxzZXJ2aWNlLm5hbWUSFQoTYW9sLXJlc2lsaWVuY2UtdGVzdBJLEkkJAAAytJHUsxgQCSoWChRhb2wgcmVzaWxpZW5jZSBldmVudDIkCgpldmVudC5uYW1lEhYKFGFvbC5yZXNpbGllbmNlLmV2ZW50"

echo "[act] 1/4 stopping apm-server to simulate a central-backend outage…"
docker compose stop apm-server

echo "[act] 2/4 POSTing the probe to the Collector (service.name=$SERVICE_NAME) while the backend is down…"
code=$(printf '%s' "$probe_payload" | base64 -d | curl -s -o /dev/null -w '%{http_code}' \
  -X POST "$OTEL_COLLECTOR_URL/v1/logs" \
  -H 'Content-Type: application/x-protobuf' \
  --data-binary @-)
[ "$code" = 200 ] || fail "Collector rejected the probe during the outage: HTTP $code (expected 200 — it should accept and queue)"
echo "[act] Collector accepted and queued the probe -> HTTP $code"

echo "[act] 3/4 waiting for the batch to flush to disk, then restarting otel-collector…"
sleep 8
docker compose restart otel-collector
wait_collector || {
  docker compose ps
  fail "otel-collector did not come back after restart"
}

mid=$(es_count)
[ "${mid:-0}" -le "${baseline:-0}" ] || fail "probe reached ES while apm-server was stopped (count $mid > baseline $baseline) — outage not actually simulated"
echo "[act] confirmed: probe not in ES during the outage (count still $mid)"

echo "[act] 4/4 starting apm-server and waiting for it to recover…"
docker compose start apm-server
wait_healthy aol-apm-server 60 || {
  docker compose ps
  fail "apm-server did not become healthy after restart"
}

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
