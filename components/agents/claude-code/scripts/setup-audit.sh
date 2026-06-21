#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -lt 8 ] || [ "$#" -gt 9 ]; then
  echo "usage: setup-audit.sh <agent_home> <es_url> <api_key> <timeout_ms> <up_enabled> <up_content> <tc_enabled> <tc_content> [marker_endpoint]" >&2
  exit 1
fi
agent_home=$1
es_url=$2
api_key=$3
timeout_ms=$4
user_prompt_enabled=$5
user_prompt_content=$6
tool_call_enabled=$7
tool_call_content=$8
# Ownership marker endpoint. Defaults to the audit ES data-plane URL (the lab's
# single-concern behaviour); a caller sharing one home across concerns passes a
# unified value so every bundle file carries the same marker.
marker_endpoint=${9:-$es_url}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

"$SCRIPT_DIR/render-hook.sh" "$agent_home" "$marker_endpoint"
"$SCRIPT_DIR/render-agent-audit.sh" "$es_url" "$agent_home" "$api_key" "$timeout_ms" \
  "$user_prompt_enabled" "$user_prompt_content" "$tool_call_enabled" "$tool_call_content" "$marker_endpoint"
