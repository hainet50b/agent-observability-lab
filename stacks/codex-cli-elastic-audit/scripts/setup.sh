#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

scope=local
target=""
config=""
while [ "$#" -gt 0 ]; do
  case $1 in
  --scope)
    scope=${2:-}
    shift 2
    ;;
  --target)
    target=${2:-}
    shift 2
    ;;
  *)
    config=$1
    shift
    ;;
  esac
done

"$script_dir/setup-backend.sh" ${config:+"$config"}
echo
"$script_dir/setup-config.sh" --scope "$scope" ${target:+--target "$target"} ${config:+"$config"}
