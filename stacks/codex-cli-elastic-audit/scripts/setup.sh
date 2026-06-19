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

echo "[setup] 1/3 — Agent Audit data streams"
"$components_dir/backends/elastic-audit/scripts/setup-elasticsearch.sh" | indent

echo
echo "[setup] 2/3 — Codex audit config"
"$components_dir/agents/codex-cli/scripts/setup-audit.sh" "$stack_dir" "$ES_URL" | indent

echo
echo "[setup] 3/3 — Kibana saved objects"
"$components_dir/backends/elastic-audit/scripts/setup-kibana.sh" | indent
