#!/usr/bin/env bash
set -euo pipefail

target_dir=${1:-}
endpoint=${2:-}

if [ -z "$target_dir" ] || [ -z "$endpoint" ]; then
  echo "Usage: render-mcp.sh <target-dir> <endpoint>" >&2
  exit 2
fi

config="$target_dir/.codex/config.toml"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
component_dir=$(cd -- "$script_dir/.." && pwd)
template="$component_dir/templates/mcp.template.toml"
# shellcheck source=/dev/null
. "$component_dir/../shared/config-place/lib/config-place-core.sh"

[ -f "$template" ] || {
  echo "FAIL: template not found: $template" >&2
  exit 1
}

config_place::append_section 'mcp' 'codex-cli' "$endpoint" "$template" "$config" '[mcp_servers.elasticsearch]'
