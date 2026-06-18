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

echo "[setup] 1/4 — Agent Audit data streams (logs-agent_audit.user_prompt-default + .tool_call-default)"
"$components_dir/backends/elastic-audit/scripts/setup-agent-audit.sh" | indent

echo
echo "[setup] 2/4 — agent config: .codex/agent-audit.conf (audit delivery)"
"$components_dir/agents/codex-cli/scripts/render-agent-audit.sh" "$ES_URL" "$stack_dir" | indent

echo
echo "[setup] 3/4 — .codex/config.toml: UserPromptSubmit + PostToolUse Agent Audit hooks (render-hooks), then Elasticsearch MCP appended (render-mcp)"
"$components_dir/agents/codex-cli/scripts/render-hooks.sh" "$stack_dir" | indent
"$components_dir/agents/codex-cli/scripts/render-mcp.sh" "$stack_dir" | indent

echo
echo "[setup] 4/4 — Kibana saved objects: Agent Audit data views + saved searches"
"$components_dir/backends/services/kibana/scripts/import-kibana-objects.sh" agent-audit | indent

echo
echo "[setup] done ✓ — point a Codex session at this directory (see ../README.md); verify with scripts/verify-agent-audit.sh and scripts/verify-tool-call-audit.sh."
