#!/usr/bin/env bash
#
# setup.sh — one-shot bootstrap for the claude-code-elastic stack.
#
# Run once after `docker compose up -d` (when the services are healthy). Performs
# every post-up bootstrap step so you don't run them individually:
#   1. backend — trace-routing ingest pipeline
#   2. backend — prompts-audit index
#   3. Kibana saved objects (backend cross-agent view, then the agent assets)
#   4. agent — render .claude/settings.local.json (telemetry env + audit hook)
#      from the agent-owned template, so a `claude` launched from this directory
#      auto-emits telemetry and audits prompts (no manual export / hook registration)
#
# Steps 1–3 are idempotent. Step 4 is create-if-absent (your edits survive a
# re-run; delete the file to regenerate). Override endpoints with ES_URL /
# KIBANA_URL. Verification (smoke-test.sh) stays separate. Run from anywhere.
#
# On Windows use setup.ps1 instead — it renders the PowerShell-correct hook.

set -euo pipefail

OTLP_ENDPOINT=http://localhost:8200
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STACK_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
C="$SCRIPT_DIR/../../../components"

echo "[setup] 1/4 — trace-routing ingest pipeline"
"$C/backends/elastic/scripts/setup-trace-routing.sh" "$@"

echo "[setup] 2/4 — prompts-audit index"
"$C/backends/elastic/scripts/setup-prompt-audit.sh" "$@"

echo "[setup] 3/4 — Kibana saved objects"
"$C/backends/elastic/scripts/import-kibana-objects.sh" "$@"
"$C/agents/claude-code/scripts/import-kibana-objects.sh" "$@"

echo "[setup] 4/4 — local Claude Code settings (telemetry env + audit hook)"
"$C/agents/claude-code/scripts/render-settings.sh" "$OTLP_ENDPOINT" "$STACK_DIR"

echo "[setup] done ✓ — run 'claude' from this directory; verify with scripts/smoke-test.sh."
