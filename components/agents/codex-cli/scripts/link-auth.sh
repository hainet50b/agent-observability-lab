#!/usr/bin/env bash

set -euo pipefail

codex_home=${1:-}
endpoint=${2:-}
source=${3:-"$HOME/.codex/auth.json"}
if [ -z "$codex_home" ] || [ -z "$endpoint" ]; then
  echo "usage: link-auth.sh <codex-home> <endpoint> [source-auth-json]" >&2
  exit 2
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=/dev/null
. "$COMPONENT_DIR/../shared/config-place/lib/config-place-core.sh"

target="$codex_home/auth.json"

if [ ! -e "$source" ]; then
  config_place::log "auth: no $source found; run 'codex login' under CODEX_HOME ($codex_home)"
  exit 0
fi
if [ -e "$target" ]; then
  config_place::log "auth: existing auth.json kept at $target"
  exit 0
fi

mkdir -p "$codex_home"
if ln -s "$source" "$target" 2>/dev/null && [ -L "$target" ]; then
  config_place::log "auth: linked $target -> $source"
else
  [ -e "$target" ] || cp "$source" "$target" || config_place::die "auth: could not copy $source to $target"
  config_place::log "auth: copied $source to $target (not a link; a copy can go stale on token refresh)"
fi
# shellcheck disable=SC2154 # config_place_marker_suffix set by the sourced core
config_place::write_marker "$target$config_place_marker_suffix" 'codex-cli' "$endpoint" "$target"
