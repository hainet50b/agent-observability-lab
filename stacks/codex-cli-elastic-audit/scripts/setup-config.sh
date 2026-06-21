#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
stack_dir=$(cd -- "$script_dir/.." && pwd)
components_dir="$script_dir/../../../components"

scope=local
target=""
config=""
teardown=0
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
  --teardown)
    teardown=1
    shift
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
  if [ "$teardown" -eq 1 ]; then
    "$components_dir/agents/codex-cli/scripts/teardown-local.sh" "$target" "$AUDIT_ES_URL"
  else
    "$components_dir/agents/codex-cli/scripts/setup-audit.sh" "$target" "$AUDIT_ES_URL" "$AUDIT_API_KEY" \
      "$AUDIT_TIMEOUT_MS" "$AUDIT_UP_ENABLED" "$AUDIT_UP_CONTENT" "$AUDIT_TC_ENABLED" "$AUDIT_TC_CONTENT"
    "$components_dir/agents/codex-cli/scripts/render-mcp.sh" "$target" "$AUDIT_ES_URL"
  fi
  ;;
project)
  [ -n "$target" ] || {
    echo "FAIL: --scope project requires --target <dir>" >&2
    exit 2
  }
  if [ "$teardown" -eq 1 ]; then
    "$components_dir/agents/codex-cli/scripts/teardown-local.sh" "$target" "$AUDIT_ES_URL"
  else
    "$components_dir/agents/codex-cli/scripts/setup-audit.sh" "$target" "$AUDIT_ES_URL" "$AUDIT_API_KEY" \
      "$AUDIT_TIMEOUT_MS" "$AUDIT_UP_ENABLED" "$AUDIT_UP_CONTENT" "$AUDIT_TC_ENABLED" "$AUDIT_TC_CONTENT"
  fi
  ;;
managed)
  # Audit-only managed deploy: hooks, no telemetry. The audit ES url keys the
  # marker/ownership in place of an OTLP logs endpoint.
  if [ "$teardown" -eq 1 ]; then
    "$components_dir/agents/codex-cli/scripts/teardown-managed.sh" --with-hooks
  else
    "$components_dir/agents/codex-cli/scripts/setup-managed.sh" --with-hooks --es-url "$AUDIT_ES_URL" --es-api-key "$AUDIT_API_KEY" \
      --timeout-ms "$AUDIT_TIMEOUT_MS" \
      --capture-user-prompt-enabled "$AUDIT_UP_ENABLED" --capture-user-prompt-content "$AUDIT_UP_CONTENT" \
      --capture-tool-call-enabled "$AUDIT_TC_ENABLED" --capture-tool-call-content "$AUDIT_TC_CONTENT"
  fi
  ;;
*)
  echo "FAIL: unknown --scope '$scope' (expected local|project|managed)" >&2
  exit 2
  ;;
esac
