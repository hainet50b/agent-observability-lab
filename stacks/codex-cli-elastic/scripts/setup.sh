#!/usr/bin/env bash
#
# setup.sh — one-shot post-up bootstrap for the codex-cli-elastic OTLP telemetry
# path. Run once after `docker compose up -d` reports healthy. Each step delegates
# to a component script (see README.md for what each does, SPEC/ for the rationale).
# Steps are idempotent / create-if-absent, so re-running is safe. Override the ES
# endpoint with ES_URL and the Kibana URL with KIBANA_URL. On Windows use setup.ps1.
#
# Verification (smoke-test.sh) and prompt/tool-call audit (the codex-cli-elastic-audit
# stack) are separate concerns, not part of this script.

set -euo pipefail

OTLP_ENDPOINT=http://localhost:8200
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
STACK_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
C="$SCRIPT_DIR/../../../components"

echo "[setup] 1/4 — trace-routing ingest pipeline"
"$C/backends/elastic/scripts/setup-trace-routing.sh" "$@"

echo "[setup] 2/4 — logs-drop ingest pipeline (logs-apm.app@custom)"
"$C/backends/elastic/scripts/setup-logs-drop.sh" "$@"

echo "[setup] 3/4 — Codex session config (.codex/config.toml: [otel] + Elasticsearch MCP)"
"$C/agents/codex-cli/scripts/render-otel.sh" "$OTLP_ENDPOINT" "$STACK_DIR"
"$C/agents/codex-cli/scripts/render-mcp.sh" "$STACK_DIR"

echo "[setup] 4/4 — Kibana saved objects (data views + saved searches)"
"$C/backends/elastic/scripts/import-kibana-objects.sh" codex-cli

echo "[setup] done ✓ — point a Codex session at this directory (see ../README.md); verify with scripts/smoke-test.sh."
