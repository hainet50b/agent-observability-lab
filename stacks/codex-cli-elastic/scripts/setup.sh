#!/usr/bin/env bash
#
# setup.sh — one-shot bootstrap for the codex-cli-elastic stack.
#
# Run once after `docker compose up -d` (when the services are healthy). Performs
# the post-up bootstrap steps for this stack:
#   1. backend — trace-routing ingest pipeline (isolates service.name=codex-cli
#      spans into traces-apm-agents_codex_cli)
#   2. agent — render .codex/config.toml (Codex [otel] telemetry config) from the
#      agent-owned template, so a Codex session launched with
#      CODEX_HOME=<stack>/.codex emits into the stack without touching the user's
#      ~/.codex (a repo-local .codex/config.toml is ignored for [otel] — CODEX_HOME
#      is the supported per-project mechanism; see ../README.md)
#   3. kibana — import the saved objects: the Elastic backend's cross-agent
#      AI Agents — Traces data view, then the Codex CLI agent's per-agent data
#      views (Metrics / Events / Traces) and saved searches. Override the Kibana
#      URL with KIBANA_URL.
#
# Step 1 is idempotent, step 2 is create-if-absent (your edits survive a re-run;
# delete the file to regenerate), and step 3 imports with overwrite=true (also
# idempotent). Override the ES endpoint with ES_URL, the Kibana URL with
# KIBANA_URL. Verification (smoke-test.sh) stays separate. Run from anywhere.
#
# NOT done here (deferred — see ../README.md): the prompts-audit index + capture
# hook are Claude-Code-specific (Codex has no such hook), and the remaining Codex
# saved searches + dashboard await further characterization of Codex's telemetry
# (the data views and the first saved search, Tool Results, import in step 3). On
# Windows use setup.ps1 instead.

set -euo pipefail

OTLP_ENDPOINT=http://localhost:8200
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STACK_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
C="$SCRIPT_DIR/../../../components"

echo "[setup] 1/3 — trace-routing ingest pipeline"
"$C/backends/elastic/scripts/setup-trace-routing.sh" "$@"

echo "[setup] 2/3 — local Codex session config (.codex/config.toml, [otel] telemetry)"
"$C/agents/codex-cli/scripts/render-config.sh" "$OTLP_ENDPOINT" "$STACK_DIR"

echo "[setup] 3/3 — Kibana saved objects (1/2): backend cross-agent AI Agents — Traces view"
"$C/backends/elastic/scripts/import-kibana-objects.sh" "$@"
echo "[setup] 3/3 — Kibana saved objects (2/2): Codex agent data views + saved searches"
"$C/agents/codex-cli/scripts/import-kibana-objects.sh" "$@"

echo "[setup] done ✓ — point a Codex session at this directory (see ../README.md); verify with scripts/smoke-test.sh."
