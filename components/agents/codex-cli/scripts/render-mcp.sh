#!/usr/bin/env bash
set -euo pipefail

target_dir=${1:-}

if [ -z "$target_dir" ]; then
  echo "Usage: render-mcp.sh <target-dir>" >&2
  exit 2
fi

config="$target_dir/.codex/config.toml"

if [ -e "$config" ] && grep -qF '[mcp_servers.elasticsearch]' "$config"; then
  echo "Skipped: $config already has [mcp_servers.elasticsearch]"
  exit 0
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
component_dir=$(cd -- "$script_dir/.." && pwd)
template="$component_dir/mcp.template.toml"

[ -f "$template" ] || {
  echo "FAIL: template not found: $template" >&2
  exit 1
}

mkdir -p "$target_dir/.codex"
[ -e "$config" ] && printf '\n' >>"$config"
cat "$template" >>"$config"
