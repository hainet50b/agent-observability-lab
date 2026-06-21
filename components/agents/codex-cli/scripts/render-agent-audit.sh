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
# Ownership marker endpoint. Defaults to the audit ES URL (the conf's data value
# stays the ES URL regardless); a caller sharing one home across concerns passes
# a unified value so every bundle file carries the same marker.
marker_endpoint=${9:-$es_url}

if [ -z "$es_url" ] || [ -z "$target_dir" ] || [ -z "$timeout_ms" ] ||
  [ -z "$user_prompt_enabled" ] || [ -z "$user_prompt_content" ] ||
  [ -z "$tool_call_enabled" ] || [ -z "$tool_call_content" ]; then
  echo "Usage: render-agent-audit.sh <es-url> <target-dir> <api-key> <timeout-ms> <up-enabled> <up-content> <tc-enabled> <tc-content> [marker-endpoint]" >&2
  exit 2
fi

config="$target_dir/.codex/agent-audit.conf"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
component_dir=$(cd -- "$script_dir/.." && pwd)
template="$component_dir/templates/agent-audit.template.conf"
# shellcheck source=/dev/null
. "$component_dir/../shared/config-place/lib/config-place-core.sh"

[ -f "$template" ] || {
  echo "FAIL: template not found: $template" >&2
  exit 1
}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
sed \
  -e "s#@@ES_URL@@#$es_url#" \
  -e "s#@@ES_API_KEY@@#$api_key#" \
  -e "s#@@ES_TIMEOUT_MS@@#$timeout_ms#" \
  -e "s#@@CAPTURE_USER_PROMPT_ENABLED@@#$user_prompt_enabled#" \
  -e "s#@@CAPTURE_USER_PROMPT_CONTENT@@#$user_prompt_content#" \
  -e "s#@@CAPTURE_TOOL_CALL_ENABLED@@#$tool_call_enabled#" \
  -e "s#@@CAPTURE_TOOL_CALL_CONTENT@@#$tool_call_content#" \
  "$template" >"$tmp"

config_place::place_file 'agent-audit' 'codex-cli' "$marker_endpoint" "$tmp" "$config"
config_place::place_self_ignore 'codex-cli' "$marker_endpoint" "$target_dir/.codex"
