#!/usr/bin/env bash
#
# setup.sh — one-shot bootstrap for the codex-cli-elastic-audit stack.
#
# The audit counterpart to codex-cli-elastic/scripts/setup.sh. Run once after
# `docker compose up -d` (when Elasticsearch + Kibana are healthy). This stack is
# the DIRECT Agent Audit path only (hook → Elasticsearch); there is no OTLP / APM
# telemetry here (no [otel] / render-otel) — the only .codex/config.toml content
# is the Elasticsearch MCP server, rendered by render-mcp. The post-up bootstrap
# steps:
#   1. backend — provision the Agent Audit data streams
#      (logs-agent_audit.user_prompt-default and logs-agent_audit.tool_call-default)
#      + their strict index templates, per SPEC/agent-audit.md. Agent-cross-cutting,
#      so it lives in the elastic-audit backend.
#   2. agent — render .codex/agent-audit.toml (the Agent Audit hooks' Elasticsearch
#      delivery config) from the agent-owned template, with this stack's local ES
#      defaults (url = ES_URL, security-disabled so api_key empty; see
#      SPEC/agent-audit.md). The hooks (step 3) read this file at run time for their
#      ES endpoint / data stream / timeout / audit mode.
#   3. agent — register the UserPromptSubmit + PostToolUse Agent Audit hooks as
#      inline [hooks] tables in .codex/config.toml (render-hooks), then append the
#      Elasticsearch MCP server to the same config.toml (render-mcp, last). At run
#      time each hook reshapes its event into the canonical agent_audit document and
#      POSTs it (fail-open, short timeout) to the local Agent Audit data stream,
#      using the step-2 delivery config. Lab mode stores the captured text in
#      plaintext (no sealing yet).
#   4. kibana — import the Agent Audit saved objects (the Agent Audit — User Prompts
#      and Agent Audit — Tool Calls data views + saved searches). Override the
#      Kibana URL with KIBANA_URL.
#
# Step 1 is idempotent, steps 2 and 3 are create-if-absent (your edits survive a
# re-run; delete the file to regenerate), and step 4 imports with overwrite=true
# (also idempotent). Override the ES endpoint with ES_URL, the Kibana URL with
# KIBANA_URL. Verification (verify-agent-audit.sh / verify-tool-call-audit.sh)
# stays separate. Run from anywhere. On Windows use setup.ps1 instead.
#
# NOT done here (deferred — see ../README.md): prompt/tool-I/O sealing/encryption
# is not built yet — the hooks deliver captured text in plaintext (lab mode).

set -euo pipefail

ES_URL=${ES_URL:-http://localhost:9200}
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
STACK_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
C="$SCRIPT_DIR/../../../components"

echo "[setup] 1/4 — Agent Audit data streams (logs-agent_audit.user_prompt-default + .tool_call-default)"
"$C/backends/elastic-audit/scripts/setup-agent-audit.sh" "$@"

echo "[setup] 2/4 — agent config: .codex/agent-audit.toml (audit delivery)"
"$C/agents/codex-cli/scripts/render-agent-audit.sh" "$ES_URL" "$STACK_DIR"

echo "[setup] 3/4 — .codex/config.toml: UserPromptSubmit + PostToolUse Agent Audit hooks (render-hooks), then Elasticsearch MCP appended (render-mcp)"
"$C/agents/codex-cli/scripts/render-hooks.sh" "$STACK_DIR"
"$C/agents/codex-cli/scripts/render-mcp.sh" "$STACK_DIR"

echo "[setup] 4/4 — Kibana saved objects: Agent Audit data views + saved searches"
"$C/backends/elastic-audit/scripts/import-kibana-objects.sh" "$@"

echo "[setup] done ✓ — point a Codex session at this directory (see ../README.md); verify with scripts/verify-agent-audit.sh and scripts/verify-tool-call-audit.sh."
