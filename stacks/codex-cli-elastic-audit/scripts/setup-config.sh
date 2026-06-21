#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
stack_dir=$(cd -- "$script_dir/.." && pwd)
components_dir="$script_dir/../../../components"

scope=local
target=""
config=""
while [ "$#" -gt 0 ]; do
  case $1 in
  --scope)
    scope=${2:-}
    shift 2
    ;;
  --target)
    target=${2:-}
    shift 2
    ;;
  *)
    config=$1
    shift
    ;;
  esac
done
config=${config:-$stack_dir/setup.conf}
[ -f "$config" ] || {
  echo "FAIL: config file not found: $config" >&2
  exit 2
}

while IFS='=' read -r key val; do
  case $key in
  agent_audit.elasticsearch.url) AUDIT_ES_URL=$val ;;
  agent_audit.elasticsearch.timeout_ms) AUDIT_TIMEOUT_MS=$val ;;
  agent_audit.capture.user_prompt.enabled) AUDIT_UP_ENABLED=$val ;;
  agent_audit.capture.user_prompt.content) AUDIT_UP_CONTENT=$val ;;
  agent_audit.capture.tool_call.enabled) AUDIT_TC_ENABLED=$val ;;
  agent_audit.capture.tool_call.content) AUDIT_TC_CONTENT=$val ;;
  esac
done <"$config"
for kv in \
  "agent_audit.elasticsearch.url=${AUDIT_ES_URL:-}" \
  "agent_audit.elasticsearch.timeout_ms=${AUDIT_TIMEOUT_MS:-}" \
  "agent_audit.capture.user_prompt.enabled=${AUDIT_UP_ENABLED:-}" \
  "agent_audit.capture.user_prompt.content=${AUDIT_UP_CONTENT:-}" \
  "agent_audit.capture.tool_call.enabled=${AUDIT_TC_ENABLED:-}" \
  "agent_audit.capture.tool_call.content=${AUDIT_TC_CONTENT:-}"; do
  [ -n "${kv#*=}" ] || {
    echo "FAIL: $config: missing or empty key '${kv%%=*}'." >&2
    exit 2
  }
done

# Optional secret overlay (gitignored): agent_audit.elasticsearch.api_key.
# Absent file or key -> empty, no error.
AUDIT_API_KEY=""
local_config="$stack_dir/setup.local.conf"
if [ -f "$local_config" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
    agent_audit.elasticsearch.api_key=*) AUDIT_API_KEY=${line#agent_audit.elasticsearch.api_key=} ;;
    esac
  done <"$local_config"
fi

case $scope in
local)
  [ -z "$target" ] || {
    echo "FAIL: --scope local does not take --target (use --scope project to deploy into a directory)" >&2
    exit 2
  }
  target=$stack_dir
  "$components_dir/agents/codex-cli/scripts/setup-audit.sh" "$target" "$AUDIT_ES_URL" "$AUDIT_API_KEY" \
    "$AUDIT_TIMEOUT_MS" "$AUDIT_UP_ENABLED" "$AUDIT_UP_CONTENT" "$AUDIT_TC_ENABLED" "$AUDIT_TC_CONTENT"
  "$components_dir/agents/codex-cli/scripts/render-mcp.sh" "$target"
  ;;
project)
  [ -n "$target" ] || {
    echo "FAIL: --scope project requires --target <dir>" >&2
    exit 2
  }
  "$components_dir/agents/codex-cli/scripts/setup-audit.sh" "$target" "$AUDIT_ES_URL" "$AUDIT_API_KEY" \
    "$AUDIT_TIMEOUT_MS" "$AUDIT_UP_ENABLED" "$AUDIT_UP_CONTENT" "$AUDIT_TC_ENABLED" "$AUDIT_TC_CONTENT"
  ;;
managed)
  echo "FAIL: managed scope (audit hooks) is not wired yet — see PRD deploy 4/4." >&2
  exit 2
  ;;
*)
  echo "FAIL: unknown --scope '$scope' (expected local|project|managed)" >&2
  exit 2
  ;;
esac
