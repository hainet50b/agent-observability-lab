#!/usr/bin/env bash

set -euo pipefail

target_dir=${1:-}
logs_endpoint=${2:-}
traces_endpoint=${3:-}
metrics_endpoint=${4:-}
api_key=${5:-}

if [ -z "$target_dir" ] || [ -z "$logs_endpoint" ] || [ -z "$traces_endpoint" ] || [ -z "$metrics_endpoint" ]; then
  echo "Usage: render-otel.sh <target-dir> <logs-endpoint> <traces-endpoint> <metrics-endpoint> [otlp-api-key]" >&2
  exit 2
fi

# Optional OTLP auth. Empty key -> empty (headers render byte-identically as `{}`);
# present -> ` Authorization = "ApiKey <key>" ` inside the per-exporter table.
headers=""
if [ -n "$api_key" ]; then
  headers=" Authorization = \"ApiKey $api_key\" "
fi

config="$target_dir/.codex/config.toml"

if [ -e "$config" ]; then
  echo "Skipped: $config already exists (delete to regenerate)"
  exit 0
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
component_dir=$(cd -- "$script_dir/.." && pwd)
template="$component_dir/templates/otel.template.toml"

[ -f "$template" ] || {
  echo "FAIL: template not found: $template" >&2
  exit 1
}

mkdir -p "$target_dir/.codex"
sed -e "s#@@OTLP_LOGS_ENDPOINT@@#$logs_endpoint#" \
  -e "s#@@OTLP_TRACES_ENDPOINT@@#$traces_endpoint#" \
  -e "s#@@OTLP_METRICS_ENDPOINT@@#$metrics_endpoint#" \
  -e "s#@@OTLP_HEADERS@@#$headers#g" \
  "$template" >"$config"
