#!/usr/bin/env pwsh
# setup.ps1 — one-shot bootstrap for the codex-cli-elastic-audit stack.
#
# PowerShell mirror of setup.sh. The audit counterpart to codex-cli-elastic's
# setup.ps1. Run once after `docker compose up -d` (Elasticsearch + Kibana
# healthy). This stack is the DIRECT Agent Audit path only (hook → Elasticsearch);
# there is no OTLP / APM telemetry, so there is NO render-config step (no
# .codex/config.toml). Steps: 1) provision the Agent Audit data streams
# (logs-agent_audit.user_prompt-default + logs-agent_audit.tool_call-default) +
# their strict index templates per SPEC/agent-audit.md (agent-cross-cutting,
# elastic-audit-backend-owned)  2) render .codex/agent-audit.toml (the Agent Audit
# hooks' Elasticsearch delivery config) from the agent-owned template with this
# stack's local ES defaults (url = -EsUrl, security-disabled so api_key empty; see
# SPEC/agent-audit.md); the step-3 hooks read this at run time  3) register the
# UserPromptSubmit + PostToolUse Agent Audit hooks into .codex/hooks.json (the only
# Codex config under CODEX_HOME for this stack — no config.toml). At run time each
# hook reshapes its event into the canonical agent_audit document and POSTs it
# (fail-open, short timeout) to the local Agent Audit data stream using the step-2
# config; lab mode stores captured text in plaintext (no sealing yet)  4) import
# the Agent Audit Kibana saved objects (the Agent Audit — User Prompts and Agent
# Audit — Tool Calls data views + saved searches). Step 1 idempotent; steps 2 and 3
# create-if-absent; step 4 imports with overwrite=true. Override the ES endpoint
# with -EsUrl, the Kibana URL with the KIBANA_URL env var. Verification
# (verify-agent-audit.ps1 / verify-tool-call-audit.ps1) stays separate.
#
# NOT done here (deferred): prompt/tool-I/O sealing/encryption is not built yet —
# the hooks deliver captured text in plaintext (lab mode).

[CmdletBinding()]
param(
    [string]$EsUrl
)

$ErrorActionPreference = 'Stop'
$StackDir = Split-Path -Parent $PSScriptRoot
$C = Join-Path $PSScriptRoot '../../../components'

$es = @{}; if ($EsUrl) { $es['EsUrl'] = $EsUrl }
$EsUrlLocal = if ($EsUrl) { $EsUrl } else { 'http://localhost:9200' }

function Invoke-Step {
    param([string]$Label, [string]$Path, [hashtable]$StepArgs)
    Write-Host "[setup] $Label"
    $global:LASTEXITCODE = 0
    & $Path @StepArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Invoke-Step -Label '1/4 - Agent Audit data streams (logs-agent_audit.user_prompt-default + .tool_call-default)' `
    -Path (Join-Path $C 'backends/elastic-audit/scripts/setup-agent-audit.ps1') -StepArgs $es
Invoke-Step -Label '2/4 - Agent Audit delivery config (.codex/agent-audit.toml, local ES defaults)' `
    -Path (Join-Path $C 'agents/codex-cli/scripts/render-agent-audit.ps1') `
    -StepArgs @{ EsUrl = $EsUrlLocal; TargetDir = $StackDir }
Invoke-Step -Label '3/4 - UserPromptSubmit + PostToolUse Agent Audit hooks (.codex/hooks.json, ES delivery)' `
    -Path (Join-Path $C 'agents/codex-cli/scripts/render-hooks.ps1') `
    -StepArgs @{ TargetDir = $StackDir }
Invoke-Step -Label '4/4 - Kibana saved objects: Agent Audit data views + saved searches' `
    -Path (Join-Path $C 'backends/elastic-audit/scripts/import-kibana-objects.ps1') -StepArgs @{}

Write-Host "[setup] done - point a Codex session at this directory (see ../README.md); verify with scripts/verify-agent-audit.ps1 and scripts/verify-tool-call-audit.ps1."
