#!/usr/bin/env bash
#
# setup.sh — one-shot bootstrap for the claude-code-elastic-audit stack.
#
# The audit counterpart to claude-code-elastic/scripts/setup.sh. Run once after
# `docker compose up -d` (when Elasticsearch + Kibana are healthy). This stack is
# the DIRECT Agent Audit path only (hook → Elasticsearch); there is no OTLP / APM
# telemetry here (no telemetry env / render-otel) — the agent home carries only the
# UserPromptSubmit audit hook, its delivery config, and the Elasticsearch MCP. The
# post-up bootstrap steps:
#   1. backend — provision the Agent Audit data streams
#      (logs-agent_audit.user_prompt-default and logs-agent_audit.tool_call-default)
#      + their strict index templates, per SPEC/agent-audit.md. Agent-cross-cutting,
#      so it lives in the elastic-audit backend. (Claude captures only user_prompt
#      today; the tool_call stream is provisioned by the shared backend script.)
#   2. agent — register the UserPromptSubmit Agent Audit hook in
#      .claude/settings.local.json (render-hook), wiring the hook command to this
#      platform's capture-prompt.sh with an injected --config pointing at the
#      delivery config rendered in step 3.
#   3. agent — render .claude/agent-audit.conf (the hook's Elasticsearch delivery
#      config) from the agent-owned template, with this stack's local ES defaults
#      (url = ES_URL, security-disabled so api_key empty; see SPEC/agent-audit.md).
#      The hook reads this file at run time for its ES endpoint / data stream /
#      timeout / audit mode.
#   4. agent — render .mcp.json (project-scoped Elasticsearch MCP server) so a
#      `claude` launched here can query the backend (interactive-approval).
#   5. kibana — import the Agent Audit saved objects (the Agent Audit — User Prompts
#      and Agent Audit — Tool Calls data views + saved searches). Override the
#      Kibana URL with KIBANA_URL.
#
# Step 1 is idempotent, steps 2–4 are create-if-absent (your edits survive a
# re-run; delete the file to regenerate), and step 5 imports with overwrite=true
# (also idempotent). Override the ES endpoint with ES_URL, the Kibana URL with
# KIBANA_URL. Verification (verify-agent-audit.sh) stays separate. Run from
# anywhere. On Windows use setup.ps1 instead.
#
# NOT done here (deferred — see ../README.md): prompt sealing/encryption is not
# built yet — the hook delivers captured text in plaintext (lab mode).

set -euo pipefail

ES_URL=${ES_URL:-http://localhost:9200}
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
STACK_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
C="$SCRIPT_DIR/../../../components"

echo "[setup] 1/5 — Agent Audit data streams (logs-agent_audit.user_prompt-default + .tool_call-default)"
"$C/backends/elastic-audit/scripts/setup-agent-audit.sh"

echo "[setup] 2/5 — register the UserPromptSubmit Agent Audit hook (.claude/settings.local.json)"
"$C/agents/claude-code/scripts/render-hook.sh" "$STACK_DIR"

echo "[setup] 3/5 — agent config: .claude/agent-audit.conf (audit delivery)"
"$C/agents/claude-code/scripts/render-agent-audit.sh" "$ES_URL" "$STACK_DIR"

echo "[setup] 4/5 — local Claude Code MCP config (.mcp.json)"
"$C/agents/claude-code/scripts/render-mcp.sh" "$STACK_DIR"

echo "[setup] 5/5 — Kibana saved objects: Agent Audit data views + saved searches"
"$C/backends/elastic-audit/scripts/import-kibana-objects.sh"

echo "[setup] done ✓ — point a Claude session at this directory (see ../README.md); verify with scripts/verify-agent-audit.sh."
