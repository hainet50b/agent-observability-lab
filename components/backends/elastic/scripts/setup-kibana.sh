#!/usr/bin/env bash
set -euo pipefail

: "${KIBANA_URL:?must be set by the stack}"

[ "$#" -ge 1 ] || {
  echo "usage: setup-kibana.sh <source>... (e.g. claude)" >&2
  exit 1
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
backend_dir=$(cd -- "$script_dir/.." && pwd)
kibana_scripts="$backend_dir/../services/kibana/scripts"

"$kibana_scripts/import-kibana-assets.sh" "$@"
