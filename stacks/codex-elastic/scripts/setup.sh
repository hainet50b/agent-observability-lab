#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
stack_dir=$(cd -- "$script_dir/.." && pwd)
manifest="$stack_dir/../../agent-config/Cargo.toml"

scope=local
target=""
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
    echo "usage: setup.sh [--scope local|project|managed] [--target <dir>]" >&2
    exit 2
    ;;
  esac
done

"$script_dir/provision.sh"
echo
cargo run -q --manifest-path "$manifest" -- place --agent codex --config "$stack_dir/agent-config.toml" --scope "$scope" ${target:+--target "$target"}
