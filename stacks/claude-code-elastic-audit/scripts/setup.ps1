#!/usr/bin/env pwsh
# setup.ps1 — one-shot bootstrap for the claude-code-elastic-audit stack.
#
# PowerShell mirror of setup.sh. The audit counterpart to claude-code-elastic's
# setup.ps1. Run once after `docker compose up -d` (Elasticsearch + Kibana
# healthy). This stack is the DIRECT Agent Audit path only (hook → Elasticsearch);
# there is no OTLP / APM telemetry (no telemetry env / render-otel) — the agent
# home carries only the UserPromptSubmit audit hook, its delivery config, and the
# Elasticsearch MCP. Steps:
# 1) provision the Agent Audit data streams (logs-agent_audit.user_prompt-default +
# logs-agent_audit.tool_call-default) + their strict index templates per
# SPEC/agent-audit.md (agent-cross-cutting, elastic-audit-backend-owned)  2) register
# the UserPromptSubmit Agent Audit hook in .claude/settings.local.json (render-hook),
# wiring the hook command to this platform's capture-prompt.ps1 with an injected
# --config  3) render .claude/agent-audit.conf (the hook's Elasticsearch delivery
# config) from the agent-owned template with this stack's local ES defaults (url =
# -EsUrl, security-disabled so api_key empty); the step-2 hook reads this at run
# time  4) render .mcp.json (project-scoped Elasticsearch MCP server,
# interactive-approval)  5) import the Agent Audit Kibana saved objects (the Agent
# Audit — User Prompts and Agent Audit — Tool Calls data views + saved searches).
# Step 1 idempotent; steps 2-4 create-if-absent; step 5 imports with overwrite=true.
# Override the ES endpoint with -EsUrl, the Kibana URL with the KIBANA_URL env var.
# Verification (verify-agent-audit.ps1) stays separate.
#
# NOT done here (deferred): prompt sealing/encryption is not built yet — the hook
# delivers captured text in plaintext (lab mode).

[CmdletBinding()]
param(
    [string]$EsUrl
)

$ErrorActionPreference = 'Stop'
$StackDir = Split-Path -Parent $PSScriptRoot
$C = Join-Path $PSScriptRoot '../../../components'

$EsUrlLocal = if ($EsUrl) { $EsUrl } else { 'http://localhost:9200' }
$es = @{}; if ($EsUrl) { $es['EsUrl'] = $EsUrl }

function Invoke-Step {
    param([string]$Label, [string]$Path, [hashtable]$StepArgs)
    Write-Host "[setup] $Label"
    $global:LASTEXITCODE = 0
    & $Path @StepArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Invoke-Step -Label '1/5 - Agent Audit data streams (logs-agent_audit.user_prompt-default + .tool_call-default)' `
    -Path (Join-Path $C 'backends/elastic-audit/scripts/setup-agent-audit.ps1') -StepArgs $es
Invoke-Step -Label '2/5 - register the UserPromptSubmit Agent Audit hook (.claude/settings.local.json)' `
    -Path (Join-Path $C 'agents/claude-code/scripts/render-hook.ps1') -StepArgs @{ TargetDir = $StackDir }
Invoke-Step -Label '3/5 - agent config: .claude/agent-audit.conf (audit delivery)' `
    -Path (Join-Path $C 'agents/claude-code/scripts/render-agent-audit.ps1') `
    -StepArgs @{ EsUrl = $EsUrlLocal; TargetDir = $StackDir }
Invoke-Step -Label '4/5 - local Claude Code MCP config (.mcp.json)' `
    -Path (Join-Path $C 'agents/claude-code/scripts/render-mcp.ps1') -StepArgs @{ TargetDir = $StackDir }
Invoke-Step -Label '5/5 - Kibana saved objects: Agent Audit data views + saved searches' `
    -Path (Join-Path $C 'backends/elastic-audit/scripts/import-kibana-objects.ps1') -StepArgs @{}

Write-Host "[setup] done - point a Claude session at this directory (see ../README.md); verify with scripts/verify-agent-audit.ps1."

