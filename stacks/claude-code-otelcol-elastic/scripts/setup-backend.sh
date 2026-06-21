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

echo "[backend] 1/3 — docker compose up"
(cd "$stack_dir" && docker compose up -d --wait) | indent

echo
echo "[backend] 2/3 — Elasticsearch backend assets"
"$components_dir/backends/elastic/scripts/setup-elasticsearch.sh" claude-code | indent

echo
echo "[backend] 3/3 — Kibana saved objects"
"$components_dir/backends/elastic/scripts/setup-kibana.sh" claude-code otelcol-sidecar | indent
