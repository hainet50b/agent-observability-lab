#!/usr/bin/env bash

set -euo pipefail

es_url=${1:-}
target_dir=${2:-}
api_key=${3:-}
timeout_ms=${4:-}
user_prompt_enabled=${5:-}
user_prompt_content=${6:-}
tool_call_enabled=${7:-}
tool_call_content=${8:-}

if [ -z "$es_url" ] || [ -z "$target_dir" ] || [ -z "$timeout_ms" ] ||
  [ -z "$user_prompt_enabled" ] || [ -z "$user_prompt_content" ] ||
  [ -z "$tool_call_enabled" ] || [ -z "$tool_call_content" ]; then
  echo "usage: render-agent-audit.sh <es-url> <target-dir> <api-key> <timeout-ms> <up-enabled> <up-content> <tc-enabled> <tc-content>" >&2
  exit 2
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE="$COMPONENT_DIR/templates/agent-audit.template.conf"
config="$target_dir/.claude/agent-audit.conf"

[ -f "$TEMPLATE" ] || {
  echo "FAIL: template not found: $TEMPLATE" >&2
  exit 1
}

if [ -e "$config" ]; then
  echo "kept existing $config (delete to regenerate)"
  exit 0
fi

mkdir -p "$target_dir/.claude"
sed \
  -e "s#@@ES_URL@@#$es_url#" \
  -e "s#@@ES_API_KEY@@#$api_key#" \
  -e "s#@@ES_TIMEOUT_MS@@#$timeout_ms#" \
  -e "s#@@CAPTURE_USER_PROMPT_ENABLED@@#$user_prompt_enabled#" \
  -e "s#@@CAPTURE_USER_PROMPT_CONTENT@@#$user_prompt_content#" \
  -e "s#@@CAPTURE_TOOL_CALL_ENABLED@@#$tool_call_enabled#" \
  -e "s#@@CAPTURE_TOOL_CALL_CONTENT@@#$tool_call_content#" \
  "$TEMPLATE" >"$config"
echo "wrote $config"
