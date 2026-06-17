#!/usr/bin/env bash
#
# setup.sh — one-shot bootstrap for the codex-cli-elastic stack.
#
# Run once after `docker compose up -d` (when the services are healthy). Performs
# the post-up bootstrap steps for this stack's OTLP telemetry path. (The DIRECT
# Agent Audit path — hook → Elasticsearch — is a SEPARATE stack,
# codex-cli-elastic-audit; it is not part of this telemetry stack.)
#   1. backend — trace-routing ingest pipeline (isolates service.name=codex-cli
#      spans into traces-apm-agents_codex_cli, and drops the high-volume Codex
#      streaming spans `receiving`+`handle_responses`)
#   2. backend — logs-drop ingest pipeline (logs-apm.app@custom) dropping the
#      three verified high-volume Codex CLI streaming-delta event docs, per
#      SPEC/codex-cli-telemetry.md "Volume reduction (ingest drops)".
#   3. agent — render .codex/config.toml (Codex [otel] telemetry config + the local
#      Elasticsearch MCP server, via render-mcp) from the agent-owned templates
#      agent-owned template, so a Codex session launched with
#      CODEX_HOME=<stack>/.codex emits into the stack without touching the user's
#      ~/.codex (a repo-local .codex/config.toml is ignored for [otel] — CODEX_HOME
#      is the supported per-project mechanism; see ../README.md)
#   4. kibana — import the saved objects: the Elastic backend's cross-agent
#      AI Agents — Traces data view, then the Codex CLI agent's per-agent data
#      views (Metrics / Events / Traces) and saved searches. Override the Kibana
#      URL with KIBANA_URL.
#
# Steps 1 and 2 are idempotent, step 3 is create-if-absent (your edits survive a
# re-run; delete the file to regenerate), and step 4 imports with overwrite=true
# (also idempotent). Override the ES endpoint with ES_URL, the Kibana URL with
# KIBANA_URL. Verification (smoke-test.sh) stays separate. Run from anywhere.
#
# NOT done here (deferred — see ../README.md): a dashboard, ingest filtering,
# TTFT integration, and normalized summary indices remain deferred (the data
# views and the curated saved searches import in step 4). For prompt / tool-call
# audit, use the codex-cli-elastic-audit stack. On Windows use setup.ps1 instead.

set -euo pipefail

OTLP_ENDPOINT=http://localhost:8200
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
STACK_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
C="$SCRIPT_DIR/../../../components"

echo "[setup] 1/4 — trace-routing ingest pipeline"
"$C/backends/elastic/scripts/setup-trace-routing.sh" "$@"

echo "[setup] 2/4 — logs-drop ingest pipeline (logs-apm.app@custom)"
"$C/backends/elastic/scripts/setup-logs-drop.sh" "$@"

echo "[setup] 3/4 — Codex session config (.codex/config.toml: [otel] telemetry + Elasticsearch MCP)"
"$C/agents/codex-cli/scripts/render-otel.sh" "$OTLP_ENDPOINT" "$STACK_DIR"
"$C/agents/codex-cli/scripts/render-mcp.sh" "$STACK_DIR"

echo "[setup] 4/4 — Kibana saved objects (backend cross-agent view + Codex agent data views + saved searches)"
"$C/backends/elastic/scripts/import-kibana-objects.sh" codex-cli

echo "[setup] done ✓ — point a Codex session at this directory (see ../README.md); verify with scripts/smoke-test.sh."
