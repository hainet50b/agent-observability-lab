#!/usr/bin/env bash
#
# setup-telemetry.sh — configure Codex CLI for the telemetry concern.
#
# Concern-level façade (see the elastic backend's setup-* pattern): the stack
# passes its agent home and the OTLP endpoint; this script owns which render
# steps realize the telemetry concern. Renders the [otel] config.toml block and
# the Elasticsearch MCP config into the agent home.
#
# Usage: setup-telemetry.sh <agent_home> <otlp_endpoint>

set -euo pipefail

[ "$#" -eq 2 ] || {
  echo "usage: setup-telemetry.sh <agent_home> <otlp_endpoint>" >&2
  exit 1
}
agent_home=$1
otlp_endpoint=$2

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

"$SCRIPT_DIR/render-otel.sh" "$otlp_endpoint" "$agent_home"
"$SCRIPT_DIR/render-mcp.sh" "$agent_home"
