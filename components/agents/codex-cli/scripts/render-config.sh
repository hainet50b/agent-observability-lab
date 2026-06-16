#!/usr/bin/env bash
set -euo pipefail

otlp_endpoint=${1:-}
target_dir=${2:-}

if [ -z "$otlp_endpoint" ] || [ -z "$target_dir" ]; then
  echo "Usage: render-config.sh <otlp-endpoint> <target-dir>" >&2
  exit 2
fi

config="$target_dir/.codex/config.toml"

if [ -e "$config" ]; then
  echo "Skipped: $config already exists (delete to regenerate)"
  exit 0
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
component_dir=$(cd -- "$script_dir/.." && pwd)
template="$component_dir/config.template.toml"

[ -f "$template" ] || {
  echo "FAIL: template not found: $template" >&2
  exit 1
}

mkdir -p "$target_dir/.codex"
sed -e "s#@@OTLP_ENDPOINT@@#$otlp_endpoint#" "$template" >"$config"
