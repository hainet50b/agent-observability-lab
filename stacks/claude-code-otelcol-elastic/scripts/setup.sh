#!/usr/bin/env bash
#
# setup.sh — one-shot bootstrap for the claude-code-otelcol-elastic stack.
#
# Run this once after `docker compose up -d` (when the services are healthy).
# It performs every post-up bootstrap step in order, so you don't have to find
# and run them individually:
#   1. backend — install the trace-routing ingest pipeline (isolates Claude Code
#      spans into traces-apm-agents_claude_code)
#   2. backend — create the prompts-audit index (the prompt-audit store)
#   3. import the Kibana saved objects: the cross-agent backend data view, the
#      Claude Code agent's data views / saved searches / dashboard, and the
#      otelcol-sidecar path's self-telemetry data view + Health dashboard
#
# Idempotent: every step is safe to re-run (pipeline PUT replaces, index create
# is skipped if present, saved-object import uses overwrite=true). It calls the
# component scripts directly; override endpoints with ES_URL (default
# http://localhost:9200) and KIBANA_URL (default http://localhost:5601), which
# the sub-scripts read from the environment.
#
# Verification (smoke-test.sh, resilience-test.sh) stays separate — this script
# only sets things up.
#
# Run from anywhere — it locates its own stack directory.

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
C="$SCRIPT_DIR/../../../components"

echo "[setup] 1/3 — trace-routing ingest pipeline"
"$C/backends/elastic/scripts/setup-trace-routing.sh" "$@"

echo "[setup] 2/3 — prompts-audit index"
"$C/backends/elastic/scripts/setup-prompt-audit.sh" "$@"

echo "[setup] 3/3 — Kibana saved objects"
"$C/backends/elastic/scripts/import-kibana-objects.sh" "$@"
"$C/agents/claude-code/scripts/import-kibana-objects.sh" "$@"
"$C/paths/otelcol-sidecar/scripts/import-kibana-objects.sh" "$@"

echo "[setup] done ✓ — stack bootstrapped. Verify with scripts/smoke-test.sh"
echo "        (and scripts/resilience-test.sh for the durable-queue check)."
