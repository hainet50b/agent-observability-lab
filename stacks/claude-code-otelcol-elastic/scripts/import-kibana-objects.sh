#!/usr/bin/env bash
#
# import-kibana-objects.sh — stack import orchestrator.
#
# This stack composes the Elastic backend with the Claude Code agent over the
# otelcol-sidecar path, so a full Kibana import is three component imports run in
# order:
#   1. components/backends/elastic/scripts/import-kibana-objects.sh
#      — the cross-agent backend data view (AI Agents — Traces)
#   2. components/agents/claude-code/scripts/import-kibana-objects.sh
#      — the per-agent data views, saved searches, and Overview dashboard
#   3. components/paths/otelcol-sidecar/scripts/import-kibana-objects.sh
#      — the sidecar self-telemetry data view (OTel Collector Sidecar — Metrics)
# Keeping the script name preserves the command the user is accustomed to
# (`scripts/import-kibana-objects.sh` from the stack dir). Args ("$@", and
# KIBANA_URL inherited from the environment) forward to every sub-script;
# `set -e` fails fast on the first non-zero exit.

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMPONENTS="$SCRIPT_DIR/../../../components"

"$COMPONENTS/backends/elastic/scripts/import-kibana-objects.sh" "$@"
"$COMPONENTS/agents/claude-code/scripts/import-kibana-objects.sh" "$@"
"$COMPONENTS/paths/otelcol-sidecar/scripts/import-kibana-objects.sh" "$@"
