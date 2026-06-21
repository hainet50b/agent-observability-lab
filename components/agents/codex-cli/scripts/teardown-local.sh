#!/usr/bin/env bash

set -euo pipefail

target=${1:-}
endpoint=${2:-}
if [ -z "$target" ] || [ -z "$endpoint" ]; then
  echo "usage: teardown-local.sh <target-dir> <endpoint>" >&2
  exit 2
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=/dev/null
. "$COMPONENT_DIR/../shared/config-place/lib/config-place-core.sh"

failed=0
config="$target/.codex/config.toml"
hooks_owned=0
# shellcheck disable=SC2154 # config_place_marker_suffix set by the sourced core
[ -f "$config$config_place_marker_suffix" ] &&
  [ "$(config_place::marker_field "$config$config_place_marker_suffix" endpoint)" = "$endpoint" ] && hooks_owned=1

for key_target in \
  "config:$config" \
  "agent-audit:$target/.codex/agent-audit.conf" \
  "gitignore:$target/.codex/.gitignore"; do
  key=${key_target%%:*}
  tgt=${key_target#*:}
  config_place::remove_file "$key" "$endpoint" "$tgt" || failed=1
done

if [ "$hooks_owned" -eq 1 ] && [ -d "$target/.codex/hooks" ]; then
  rm -rf "$target/.codex/hooks"
  config_place::log "hooks: removed $target/.codex/hooks"
fi

[ "$failed" -eq 0 ] || config_place::die "one or more files were refused (see above); nothing foreign was removed"
