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
  apm_server.otlp_endpoint) otlp_endpoint=$val ;;
  esac
done <"$config"
for kv in "elasticsearch.url=${ES_URL:-}" "apm_server.otlp_endpoint=${otlp_endpoint:-}" "kibana.url=${KIBANA_URL:-}"; do
  [ -n "${kv#*=}" ] || {
    echo "FAIL: $config: missing or empty key '${kv%%=*}'." >&2
    exit 2
  }
done

export ES_URL KIBANA_URL

indent() { sed 's/^/  /'; }

echo "[setup] 1/3 — Elasticsearch backend assets"
"$components_dir/backends/elastic/scripts/setup-elasticsearch.sh" codex-cli | indent

echo
echo "[setup] 2/3 — Codex session config"
"$components_dir/agents/codex-cli/scripts/setup-telemetry.sh" "$stack_dir" "$otlp_endpoint" | indent

echo
echo "[setup] 3/3 — Kibana saved objects"
"$components_dir/backends/elastic/scripts/setup-kibana.sh" codex-cli | indent
