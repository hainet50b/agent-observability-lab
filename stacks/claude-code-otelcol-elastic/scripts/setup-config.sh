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
  --managed)
    scope=managed
    shift
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
  collector.otlp_endpoint) otlp_endpoint=$val ;;
  esac
done <"$config"
[ -n "${otlp_endpoint:-}" ] || {
  echo "FAIL: $config: missing or empty key 'collector.otlp_endpoint'." >&2
  exit 2
}

case $scope in
local)
  target=${target:-$stack_dir}
  "$components_dir/agents/claude-code/scripts/setup-telemetry.sh" "$target" "$otlp_endpoint"
  ;;
managed)
  "$components_dir/agents/claude-code/scripts/setup-managed.sh" \
    --logs-endpoint "$otlp_endpoint/v1/logs" \
    --traces-endpoint "$otlp_endpoint/v1/traces" \
    --metrics-endpoint "$otlp_endpoint/v1/metrics"
  ;;
*)
  echo "FAIL: unknown --scope '$scope' (expected local|managed)" >&2
  exit 2
  ;;
esac
