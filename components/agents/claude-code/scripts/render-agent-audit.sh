#!/usr/bin/env bash

set -euo pipefail

es_url=${1:-}
target_dir=${2:-}

if [ -z "$es_url" ] || [ -z "$target_dir" ]; then
  echo "usage: render-agent-audit.sh <es-url> <target-dir>" >&2
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
sed -e "s#@@ES_URL@@#$es_url#" "$TEMPLATE" >"$config"
echo "wrote $config"
