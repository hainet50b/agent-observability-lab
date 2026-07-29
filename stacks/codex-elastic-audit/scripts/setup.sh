#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
stack_dir=$(cd -- "$script_dir/.." && pwd)
manifest="$stack_dir/../../components/agent-config/Cargo.toml"

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
config=${config:-$stack_dir/setup.conf}

"$script_dir/setup-backend.sh" "$config"
echo
cargo run -q --manifest-path "$manifest" -- place --agent codex --config "$config" --scope "$scope" ${target:+--target "$target"}
