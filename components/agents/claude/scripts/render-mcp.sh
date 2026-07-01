#!/usr/bin/env bash

set -euo pipefail

target=${1:-}
endpoint=${2:-}
if [ -z "$target" ] || [ -z "$endpoint" ]; then
  echo "usage: render-mcp.sh <target-dir> <endpoint>" >&2
  exit 2
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE="$COMPONENT_DIR/templates/mcp.template.json"
out="$target/.mcp.json"
# shellcheck source=/dev/null
. "$COMPONENT_DIR/../shared/config-place/lib/config-place-core.sh"

[ -f "$TEMPLATE" ] || {
  echo "FAIL: template not found: $TEMPLATE" >&2
  exit 1
}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
jq 'del(._comment)' "$TEMPLATE" >"$tmp"

config_place::place_file 'mcp' 'claude' "$endpoint" "$tmp" "$out"
