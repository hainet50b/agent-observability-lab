#!/usr/bin/env bash
#
# setup-telemetry.sh — configure Claude Code for the telemetry concern.
#
# Concern-level façade: the stack expresses intent ("configure Claude Code for
# telemetry, exporting to this OTLP base") plus the values it owns (the agent
# home and the OTLP base URL). This script owns WHICH render steps realize that
# concern and their order, so the stack never enumerates the agent's render
# primitives — a change to how the telemetry config is assembled stays in this
# component. Renders the OTel env (the three OTLP signal endpoints are derived
# from the base) and the Elasticsearch MCP config into the agent home.
#
# Usage: setup-telemetry.sh <agent_home> <otlp_base>

set -euo pipefail

[ "$#" -eq 2 ] || {
  echo "usage: setup-telemetry.sh <agent_home> <otlp_base>" >&2
  exit 1
}
agent_home=$1
otlp_base=$2

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

"$SCRIPT_DIR/render-otel.sh" "$agent_home" \
  "$otlp_base/v1/logs" "$otlp_base/v1/traces" "$otlp_base/v1/metrics"
"$SCRIPT_DIR/render-mcp.sh" "$agent_home"
