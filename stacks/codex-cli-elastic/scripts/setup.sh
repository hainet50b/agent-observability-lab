#!/usr/bin/env bash
#
# setup.sh — one-shot bootstrap for the codex-cli-elastic stack.
#
# Run once after `docker compose up -d` (when the services are healthy). Performs
# the post-up bootstrap steps for this stack:
#   1. backend — trace-routing ingest pipeline (isolates service.name=codex-cli
#      spans into traces-apm-agents_codex_cli)
#   2. backend — provision the Agent Audit data stream
#      (logs-agent_audit.user_prompt-default) + its strict index template, per
#      SPEC/agent-audit.md. Agent-cross-cutting, so it lives in the backend.
#   3. agent — render .codex/config.toml (Codex [otel] telemetry config) from the
#      agent-owned template, so a Codex session launched with
#      CODEX_HOME=<stack>/.codex emits into the stack without touching the user's
#      ~/.codex (a repo-local .codex/config.toml is ignored for [otel] — CODEX_HOME
#      is the supported per-project mechanism; see ../README.md)
#   4. agent — render .codex/agent-audit.toml (the Agent Audit hook's Elasticsearch
#      delivery config) from the agent-owned template, with this stack's local ES
#      defaults (url = ES_URL, security-disabled so api_key empty; see
#      SPEC/agent-audit.md). The UserPromptSubmit hook (step 5) reads this file at
#      run time for its ES endpoint / data stream / timeout / audit mode.
#   5. agent — register the UserPromptSubmit Agent Audit hook into .codex/hooks.json
#      (coexists with config.toml under CODEX_HOME). At run time the hook reshapes
#      each submitted prompt into the canonical agent_audit.user_prompt document and
#      POSTs it (fail-open, short timeout) to the local Agent Audit data stream
#      logs-agent_audit.user_prompt-default, using the step-4 delivery config.
#      Lab mode stores the prompt text in plaintext (no sealing yet).
#   6. kibana — import the saved objects: the Elastic backend's cross-agent
#      AI Agents — Traces data view, then the Codex CLI agent's per-agent data
#      views (Metrics / Events / Traces) and saved searches. Override the Kibana
#      URL with KIBANA_URL.
#
# Steps 1 and 2 are idempotent, steps 3, 4 and 5 are create-if-absent (your edits
# survive a re-run; delete the file to regenerate), and step 6 imports with
# overwrite=true
# (also idempotent). Override the ES endpoint with ES_URL, the Kibana URL with
# KIBANA_URL. Verification (smoke-test.sh) stays separate. Run from anywhere.
#
# NOT done here (deferred — see ../README.md): prompt sealing/encryption is not
# built yet — the hook delivers prompt text in plaintext (lab mode). A dashboard,
# ingest filtering, TTFT integration, and normalized summary indices also remain
# deferred (the data views and the curated saved searches import in step 6). On
# Windows use setup.ps1 instead.

set -euo pipefail

OTLP_ENDPOINT=http://localhost:8200
ES_URL=${ES_URL:-http://localhost:9200}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STACK_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
C="$SCRIPT_DIR/../../../components"

echo "[setup] 1/6 — trace-routing ingest pipeline"
"$C/backends/elastic/scripts/setup-trace-routing.sh" "$@"

echo "[setup] 2/6 — Agent Audit data stream (logs-agent_audit.user_prompt-default)"
"$C/backends/elastic/scripts/setup-agent-audit.sh" "$@"

echo "[setup] 3/6 — local Codex session config (.codex/config.toml, [otel] telemetry)"
"$C/agents/codex-cli/scripts/render-config.sh" "$OTLP_ENDPOINT" "$STACK_DIR"

echo "[setup] 4/6 — Agent Audit delivery config (.codex/agent-audit.toml, local ES defaults)"
"$C/agents/codex-cli/scripts/render-agent-audit.sh" "$ES_URL" "$STACK_DIR"

echo "[setup] 5/6 — UserPromptSubmit Agent Audit hook (.codex/hooks.json, ES delivery)"
"$C/agents/codex-cli/scripts/render-hooks.sh" "$STACK_DIR"

echo "[setup] 6/6 — Kibana saved objects (1/2): backend cross-agent AI Agents — Traces view"
"$C/backends/elastic/scripts/import-kibana-objects.sh" "$@"
echo "[setup] 6/6 — Kibana saved objects (2/2): Codex agent data views + saved searches"
"$C/agents/codex-cli/scripts/import-kibana-objects.sh" "$@"

echo "[setup] done ✓ — point a Codex session at this directory (see ../README.md); verify with scripts/smoke-test.sh."
