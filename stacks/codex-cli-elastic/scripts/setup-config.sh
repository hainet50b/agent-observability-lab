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
  telemetry.otlp_endpoint) otlp_endpoint=$val ;;
  esac
done <"$config"
[ -n "${otlp_endpoint:-}" ] || {
  echo "FAIL: $config: missing or empty key 'telemetry.otlp_endpoint'." >&2
  exit 2
}

# Optional secret overlay (gitignored): telemetry.otlp_api_key.
# Absent file or key -> empty, no error (no auth header rendered).
OTLP_API_KEY=""
local_config="$stack_dir/setup.local.conf"
if [ -f "$local_config" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
    telemetry.otlp_api_key=*) OTLP_API_KEY=${line#telemetry.otlp_api_key=} ;;
    esac
  done <"$local_config"
fi

case $scope in
local)
  [ -z "$target" ] || {
    echo "FAIL: --scope local does not take --target (use --scope project to deploy into a directory)" >&2
    exit 2
  }
  target=$stack_dir
  "$components_dir/agents/codex-cli/scripts/setup-telemetry.sh" "$target" "$otlp_endpoint" "$OTLP_API_KEY"
  "$components_dir/agents/codex-cli/scripts/render-mcp.sh" "$target"
  ;;
project)
  [ -n "$target" ] || {
    echo "FAIL: --scope project requires --target <dir>" >&2
    exit 2
  }
  "$components_dir/agents/codex-cli/scripts/setup-telemetry.sh" "$target" "$otlp_endpoint" "$OTLP_API_KEY"
  ;;
managed)
  if [ "$teardown" -eq 1 ]; then
    teardown_args=""
    [ "$with_hooks" -eq 1 ] && teardown_args="--with-hooks"
    "$components_dir/agents/codex-cli/scripts/teardown-managed.sh" $teardown_args
  else
    "$components_dir/agents/codex-cli/scripts/setup-managed.sh" \
      --logs-endpoint "$otlp_endpoint/v1/logs" \
      --traces-endpoint "$otlp_endpoint/v1/traces" \
      --metrics-endpoint "$otlp_endpoint/v1/metrics"
  fi
  ;;
*)
  echo "FAIL: unknown --scope '$scope' (expected local|project|managed)" >&2
  exit 2
  ;;
esac
