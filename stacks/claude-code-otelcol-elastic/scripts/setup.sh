#!/usr/bin/env bash
#
# setup.sh — one-shot bootstrap for the claude-code-otelcol-elastic stack.
#
# Run once after `docker compose up -d` (when the services are healthy). Performs
# every post-up bootstrap step so you don't run them individually:
#   1. backend — trace-routing ingest pipeline
#   2. backend — prompts-audit index
#   3. Kibana saved objects (backend cross-agent view, agent assets, sidecar view)
#   4. agent — render .claude/settings.local.json (telemetry env only, pointed at
#      the Collector) from the agent-owned template, so a `claude` launched from
#      this directory auto-emits telemetry. Prompt auditing lives in the separate
#      claude-code-elastic-audit stack, not here.
#   5. agent — render .mcp.json (project-scoped Elasticsearch MCP server) so a
#      `claude` launched here can query the backend (interactive-approval).
#
# Steps 1–3 are idempotent. Steps 4–5 are create-if-absent (your edits survive a
# re-run; delete the file to regenerate). Override endpoints with ES_URL /
# KIBANA_URL. Verification (smoke-test.sh, resilience-test.sh) stays separate.
# Run from anywhere. On Windows use setup.ps1 instead.

set -euo pipefail

OTLP_ENDPOINT=http://localhost:4318
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
STACK_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
C="$SCRIPT_DIR/../../../components"

echo "[setup] 1/5 — trace-routing ingest pipeline"
"$C/backends/elastic/scripts/setup-trace-routing.sh" "$@"

echo "[setup] 2/5 — prompts-audit index"
"$C/backends/elastic/scripts/setup-prompt-audit.sh" "$@"

echo "[setup] 3/5 — Kibana saved objects"
"$C/backends/elastic/scripts/import-kibana-objects.sh" claude-code otelcol-sidecar

echo "[setup] 4/5 — local Claude Code settings (telemetry env)"
"$C/agents/claude-code/scripts/render-otel.sh" "$STACK_DIR" \
  "$OTLP_ENDPOINT/v1/logs" "$OTLP_ENDPOINT/v1/traces" "$OTLP_ENDPOINT/v1/metrics"

echo "[setup] 5/5 — local Claude Code MCP config (.mcp.json)"
"$C/agents/claude-code/scripts/render-mcp.sh" "$STACK_DIR"

echo "[setup] done ✓ — run 'claude' here; verify with smoke-test.sh (and resilience-test.sh)."
