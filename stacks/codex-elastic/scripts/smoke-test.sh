#!/usr/bin/env bash
set -euo pipefail

ES_URL=${ES_URL:-http://localhost:9200}
APM_OTLP_URL=${APM_OTLP_URL:-http://localhost:8200}
SERVICE_NAME=aol-smoke-test

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
docker info >/dev/null 2>&1 || skip "docker daemon not reachable; nothing to smoke-test"

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

echo "[act] sending synthetic OTLP/protobuf telemetry (service.name=$SERVICE_NAME)…"

metrics_payload="ClUKIgogCgxzZXJ2aWNlLm5hbWUSEAoOYW9sLXNtb2tlLXRlc3QSLxItChFhb2wuc21va2UuY291bnRlcjoYChIZAAAytJHUsxgxAQAAAAAAAAAQAhgB"
logs_payload="CmcKIgogCgxzZXJ2aWNlLm5hbWUSEAoOYW9sLXNtb2tlLXRlc3QSQRI/CQAAMrSR1LMYEAkqEQoPYW9sIHNtb2tlIGV2ZW50Mh8KCmV2ZW50Lm5hbWUSEQoPYW9sLnNtb2tlLmV2ZW50"
traces_payload="CmgKIgogCgxzZXJ2aWNlLm5hbWUSEAoOYW9sLXNtb2tlLXRlc3QSQhJAChAREREREREREREREREREREREggiIiIiIiIiIioOYW9sLnNtb2tlLnNwYW4wATkAADK0kdSzGEFAQkG0kdSzGA=="

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
post_otlp /v1/logs "$logs_payload"
post_otlp /v1/traces "$traces_payload"

es_count() {
  idx=$1
  curl -s "$ES_URL/$idx/_count?ignore_unavailable=true&allow_no_indices=true" \
    -H 'Content-Type: application/json' \
    --data "{\"query\":{\"term\":{\"service.name\":\"$SERVICE_NAME\"}}}" |
    jq -r '.count // 0'
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
assert_landed "events" "logs-apm*"
assert_landed "traces" "traces-apm*"

discover() {
  idx=$1
  curl -s "$ES_URL/$idx/_search?ignore_unavailable=true&allow_no_indices=true" \
    -H 'Content-Type: application/json' \
    --data '{"size":0,"aggs":{"svc":{"terms":{"field":"service.name","size":50}}}}' |
    jq -r '.aggregations.svc.buckets[]? | "    \(.key)  (\(.doc_count) docs)"'
}
echo "[discover] service.name values currently in the APM data streams:"
echo "  metrics-apm*:"
discover "metrics-apm*"
echo "  logs-apm*:"
discover "logs-apm*"
echo "  traces-apm*:"
discover "traces-apm*"

echo
echo "PASS: OTLP -> APM Server -> Elasticsearch pipeline verified."
echo "To point a real Codex CLI session here, run scripts/setup.sh (see ../README.md)."
echo "Inspect what is here now in Kibana (http://localhost:5601)."
