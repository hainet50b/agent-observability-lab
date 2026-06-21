#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
  echo "usage: setup-telemetry.sh <agent_home> <otlp_endpoint> [otlp_api_key] [marker_endpoint]" >&2
  exit 1
fi
agent_home=$1
otlp_endpoint=$2
otlp_api_key=${3:-}
# Ownership marker endpoint. Defaults to the OTLP data-plane endpoint (the lab's
# single-concern behaviour); a caller sharing one home across concerns passes a
# unified value so every bundle file carries the same marker.
marker_endpoint=${4:-$otlp_endpoint}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

"$SCRIPT_DIR/render-otel.sh" "$agent_home" \
  "$otlp_endpoint/v1/logs" "$otlp_endpoint/v1/traces" "$otlp_endpoint/v1/metrics" \
  "$otlp_api_key" "$marker_endpoint"
