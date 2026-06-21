#!/usr/bin/env bash

set -euo pipefail

target=${1:-}
if [ -z "$target" ]; then
  echo "usage: render-mcp.sh <target-dir>" >&2
  exit 2
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE="$COMPONENT_DIR/templates/mcp.template.json"
out="$target/.mcp.json"

[ -f "$TEMPLATE" ] || {
  echo "FAIL: template not found: $TEMPLATE" >&2
  exit 1
}

if [ -e "$out" ]; then
  echo "kept existing $out (delete to regenerate)"
  exit 0
fi

mkdir -p "$target"
jq 'del(._comment)' "$TEMPLATE" >"$out"
echo "wrote $out"
