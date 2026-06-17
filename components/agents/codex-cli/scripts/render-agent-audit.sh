#!/usr/bin/env bash
set -euo pipefail

es_url=${1:-}
target_dir=${2:-}

if [ -z "$es_url" ] || [ -z "$target_dir" ]; then
  echo "Usage: render-agent-audit.sh <es-url> <target-dir>" >&2
  exit 2
fi

config="$target_dir/.codex/agent-audit.conf"

if [ -e "$config" ]; then
  echo "Skipped: $config already exists (delete to regenerate)"
  exit 0
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
component_dir=$(cd -- "$script_dir/.." && pwd)
template="$component_dir/templates/agent-audit.template.conf"

[ -f "$template" ] || {
  echo "FAIL: template not found: $template" >&2
  exit 1
}

mkdir -p "$target_dir/.codex"
sed -e "s#@@ES_URL@@#$es_url#" "$template" >"$config"
