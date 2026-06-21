#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
stack_dir=$(cd -- "$script_dir/.." && pwd)
components_dir="$script_dir/../../../components"

scope=local
target=""
config=""
teardown=0
with_hooks=0
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
  --teardown)
    teardown=1
    shift
    ;;
  --with-hooks)
    with_hooks=1
    shift
    ;;
  *)
    config=$1
    shift
    ;;
  esac
done
if [ "$teardown" -eq 1 ] && [ "$scope" != managed ]; then
  echo "FAIL: --teardown is only valid with --scope managed" >&2
  exit 2
fi
config=${config:-$stack_dir/setup.conf}
[ -f "$config" ] || {
  echo "FAIL: config file not found: $config" >&2
  exit 2
}

while IFS='=' read -r key val; do
  case $key in
  apm_server.otlp_endpoint) otlp_endpoint=$val ;;
  esac
done <"$config"
[ -n "${otlp_endpoint:-}" ] || {
  echo "FAIL: $config: missing or empty key 'apm_server.otlp_endpoint'." >&2
  exit 2
}

case $scope in
local)
  target=${target:-$stack_dir}
  "$components_dir/agents/claude-code/scripts/setup-telemetry.sh" "$target" "$otlp_endpoint"
  ;;
managed)
  if [ "$teardown" -eq 1 ]; then
    teardown_args=""
    [ "$with_hooks" -eq 1 ] && teardown_args="--with-hooks"
    "$components_dir/agents/claude-code/scripts/teardown-managed.sh" $teardown_args
  else
    "$components_dir/agents/claude-code/scripts/setup-managed.sh" \
      --logs-endpoint "$otlp_endpoint/v1/logs" \
      --traces-endpoint "$otlp_endpoint/v1/traces" \
      --metrics-endpoint "$otlp_endpoint/v1/metrics"
  fi
  ;;
*)
  echo "FAIL: unknown --scope '$scope' (expected local|managed)" >&2
  exit 2
  ;;
esac
