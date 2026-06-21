#!/usr/bin/env bash

set -euo pipefail

target=${1:-}
logs=${2:-}
traces=${3:-}
metrics=${4:-}
headers=${5:-}

if [ -z "$target" ] || [ -z "$logs" ] || [ -z "$traces" ] || [ -z "$metrics" ]; then
  echo "usage: render-otel.sh <target-dir> <logs-endpoint> <traces-endpoint> <metrics-endpoint> [otlp-headers]" >&2
  exit 2
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE="$COMPONENT_DIR/templates/otel.template.json"
out="$target/.claude/settings.local.json"

[ -f "$TEMPLATE" ] || {
  echo "FAIL: template not found: $TEMPLATE" >&2
  exit 1
}

if [ -e "$out" ] && jq -e 'has("env")' "$out" >/dev/null 2>&1; then
  echo "kept existing env in $out (delete to regenerate)"
  exit 0
fi

env_json=$(sed \
  -e "s#@@OTLP_LOGS_ENDPOINT@@#$logs#" \
  -e "s#@@OTLP_TRACES_ENDPOINT@@#$traces#" \
  -e "s#@@OTLP_METRICS_ENDPOINT@@#$metrics#" \
  -e "s#@@OTLP_HEADERS@@#$headers#" \
  "$TEMPLATE" | jq '.env')

mkdir -p "$target/.claude"
if [ -e "$out" ]; then
  tmp=$(mktemp)
  jq --argjson env "$env_json" '.env = $env' "$out" >"$tmp"
  mv "$tmp" "$out"
  echo "added env to $out"
else
  jq -n --argjson env "$env_json" '{env: $env}' >"$out"
  echo "wrote $out"
fi
