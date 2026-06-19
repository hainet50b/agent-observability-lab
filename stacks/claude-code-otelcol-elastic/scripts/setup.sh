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
  collector.otlp_endpoint) otlp_endpoint=$val ;;
  esac
done <"$config"
for kv in "elasticsearch.url=${ES_URL:-}" "kibana.url=${KIBANA_URL:-}" "collector.otlp_endpoint=${otlp_endpoint:-}"; do
  [ -n "${kv#*=}" ] || {
    echo "FAIL: $config: missing or empty key '${kv%%=*}'." >&2
    exit 2
  }
done

export ES_URL KIBANA_URL

indent() { sed 's/^/  /'; }

echo "[setup] 1/3 — Elasticsearch backend assets (trace-routing/logs-drop pipelines + prompts-audit index)"
"$components_dir/backends/elastic/scripts/setup-elasticsearch.sh" claude-code | indent

echo
echo "[setup] 2/3 — Kibana saved objects (data views + saved searches)"
"$components_dir/backends/elastic/scripts/setup-kibana.sh" claude-code otelcol-sidecar | indent

echo
echo "[setup] 3/3 — Claude Code telemetry config (OTel env + .mcp.json)"
"$components_dir/agents/claude-code/scripts/setup-telemetry.sh" "$stack_dir" "$otlp_endpoint" | indent

echo
echo "[setup] done ✓ — run 'claude' from this directory; verify with scripts/smoke-test.sh (and scripts/resilience-test.sh)."
