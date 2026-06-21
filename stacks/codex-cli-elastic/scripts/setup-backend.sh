#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
stack_dir=$(cd -- "$script_dir/.." && pwd)
components_dir="$script_dir/../../../components"

config=${1:-$stack_dir/setup.conf}
[ -f "$config" ] || {
  echo "FAIL: config file not found: $config" >&2
  exit 2
}

while IFS='=' read -r key val; do
  case $key in
  elasticsearch.url) ES_URL=$val ;;
  kibana.url) KIBANA_URL=$val ;;
  esac
done <"$config"
for kv in "elasticsearch.url=${ES_URL:-}" "kibana.url=${KIBANA_URL:-}"; do
  [ -n "${kv#*=}" ] || {
    echo "FAIL: $config: missing or empty key '${kv%%=*}'." >&2
    exit 2
  }
done

export ES_URL KIBANA_URL

indent() { sed 's/^/  /'; }

wait_ready() {
  name=$1 url=$2
  retries=30 delay=2
  while [ "$retries" -gt 0 ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null) || code=000
    case "$code" in 2*)
      echo "$name ready at $url (HTTP $code)"
      return 0
      ;;
    esac
    retries=$((retries - 1))
    sleep "$delay"
  done
  echo "FAIL: $name not reachable at $url — bring the stack up first: docker compose up -d (and wait for healthy), then re-run." >&2
  exit 1
}

echo "[backend] 1/3 — wait for backend"
wait_ready Elasticsearch "$ES_URL/_cluster/health" | indent
wait_ready Kibana "$KIBANA_URL/api/status" | indent

echo
echo "[backend] 2/3 — Elasticsearch backend assets"
"$components_dir/backends/elastic/scripts/setup-elasticsearch.sh" codex-cli | indent

echo
echo "[backend] 3/3 — Kibana saved objects"
"$components_dir/backends/elastic/scripts/setup-kibana.sh" codex-cli | indent
