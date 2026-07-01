#!/usr/bin/env bash

set -euo pipefail

target=${1:-}
logs=${2:-}
traces=${3:-}
metrics=${4:-}
headers=${5:-}
endpoint=${6:-}

if [ -z "$target" ] || [ -z "$logs" ] || [ -z "$traces" ] || [ -z "$metrics" ] || [ -z "$endpoint" ]; then
  echo "usage: render-otel.sh <target-dir> <logs-endpoint> <traces-endpoint> <metrics-endpoint> <otlp-headers> <endpoint>" >&2
  exit 2
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE="$COMPONENT_DIR/templates/otel.template.json"
out="$target/.claude/settings.local.json"
# shellcheck source=/dev/null
. "$COMPONENT_DIR/../shared/config-place/lib/config-place-core.sh"

[ -f "$TEMPLATE" ] || {
  echo "FAIL: template not found: $TEMPLATE" >&2
  exit 1
}

env_block=$(mktemp)
tmp=$(mktemp)
trap 'rm -f "$env_block" "$tmp"' EXIT
sed \
  -e "s#@@OTLP_LOGS_ENDPOINT@@#$logs#" \
  -e "s#@@OTLP_TRACES_ENDPOINT@@#$traces#" \
  -e "s#@@OTLP_METRICS_ENDPOINT@@#$metrics#" \
  -e "s#@@OTLP_HEADERS@@#$headers#" \
  "$TEMPLATE" | jq '.env' >"$env_block"

# Merge our .env into the existing settings.local.json, preserving any other
# top-level keys (e.g. .hooks placed by the audit concern sharing this home).
base='{}'
[ -f "$out" ] && base=$(cat "$out")
printf '%s' "$base" | jq --slurpfile e "$env_block" '.env = $e[0]' >"$tmp"

config_place::place_file 'otel' 'claude' "$endpoint" "$tmp" "$out"
config_place::place_self_ignore 'claude' "$endpoint" "$target/.claude"
