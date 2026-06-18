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

echo "[setup] 1/4 — trace-routing ingest pipeline"
"$components_dir/backends/elastic/scripts/setup-trace-routing.sh" | indent

echo
echo "[setup] 2/4 — logs-drop ingest pipeline (logs-apm.app@custom)"
"$components_dir/backends/elastic/scripts/setup-logs-drop.sh" | indent

echo
echo "[setup] 3/4 — Codex session config (.codex/config.toml: [otel] + Elasticsearch MCP)"
"$components_dir/agents/codex-cli/scripts/render-otel.sh" "$otlp_endpoint" "$stack_dir" | indent
"$components_dir/agents/codex-cli/scripts/render-mcp.sh" "$stack_dir" | indent

echo
echo "[setup] 4/4 — Kibana saved objects (data views + saved searches)"
"$components_dir/backends/elastic/scripts/import-kibana-objects.sh" codex-cli | indent

echo
echo "[setup] done ✓ — point a Codex session at this directory (see ../README.md); verify with scripts/smoke-test.sh."
