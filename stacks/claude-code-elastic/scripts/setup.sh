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
for kv in "elasticsearch.url=${ES_URL:-}" "kibana.url=${KIBANA_URL:-}" "apm_server.otlp_endpoint=${otlp_endpoint:-}"; do
  [ -n "${kv#*=}" ] || {
    echo "FAIL: $config: missing or empty key '${kv%%=*}'." >&2
    exit 2
  }
done

export ES_URL KIBANA_URL

indent() { sed 's/^/  /'; }

echo "[setup] 1/4 — Elasticsearch backend assets (trace-routing/logs-drop pipelines + prompts-audit index)"
"$components_dir/backends/elastic/scripts/setup-elasticsearch.sh" | indent

echo
echo "[setup] 2/4 — Kibana saved objects (data views + saved searches)"
"$components_dir/backends/elastic/scripts/setup-kibana.sh" claude-code | indent

echo
echo "[setup] 3/4 — local Claude Code settings (telemetry env)"
"$components_dir/agents/claude-code/scripts/render-otel.sh" "$stack_dir" \
  "$otlp_endpoint/v1/logs" "$otlp_endpoint/v1/traces" "$otlp_endpoint/v1/metrics" | indent

echo
echo "[setup] 4/4 — local Claude Code MCP config (.mcp.json)"
"$components_dir/agents/claude-code/scripts/render-mcp.sh" "$stack_dir" | indent

echo
echo "[setup] done ✓ — run 'claude' from this directory; verify with scripts/smoke-test.sh."
