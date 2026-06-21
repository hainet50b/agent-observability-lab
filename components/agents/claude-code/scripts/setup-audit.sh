#!/usr/bin/env bash

set -euo pipefail

[ "$#" -eq 8 ] || {
  echo "usage: setup-audit.sh <agent_home> <es_url> <api_key> <timeout_ms> <up_enabled> <up_content> <tc_enabled> <tc_content>" >&2
  exit 1
}
agent_home=$1
es_url=$2
api_key=$3
timeout_ms=$4
user_prompt_enabled=$5
user_prompt_content=$6
tool_call_enabled=$7
tool_call_content=$8

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

"$SCRIPT_DIR/render-hook.sh" "$agent_home"
"$SCRIPT_DIR/render-agent-audit.sh" "$es_url" "$agent_home" "$api_key" "$timeout_ms" \
  "$user_prompt_enabled" "$user_prompt_content" "$tool_call_enabled" "$tool_call_content"
