#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
stack_dir=$(cd -- "$script_dir/.." && pwd)
components_dir="$script_dir/../../../components"

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
[ -f "$config" ] || {
  echo "FAIL: config file not found: $config" >&2
  exit 2
}

while IFS='=' read -r key val; do
  case $key in
  elasticsearch.url) ES_URL=$val ;;
  esac
done <"$config"
[ -n "${ES_URL:-}" ] || {
  echo "FAIL: $config: missing or empty key 'elasticsearch.url'." >&2
  exit 2
}

case $scope in
local)
  target=${target:-$stack_dir}
  "$components_dir/agents/codex-cli/scripts/setup-audit.sh" "$target" "$ES_URL"
  ;;
managed)
  echo "FAIL: managed scope (audit hooks) is not wired yet — see PRD deploy 4/4." >&2
  exit 2
  ;;
*)
  echo "FAIL: unknown --scope '$scope' (expected local|managed)" >&2
  exit 2
  ;;
esac
