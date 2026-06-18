#!/usr/bin/env pwsh
# setup.ps1 — one-shot bootstrap for the claude-code-elastic stack.
#
# PowerShell mirror of setup.sh. Run once after `docker compose up -d` (healthy).
# Steps: 1) trace-routing pipeline  2) prompts-audit index  3) Kibana saved
# objects  4) render .claude/settings.local.json (telemetry env only) from the
# agent-owned template, so a `claude` launched from this directory auto-emits
# telemetry. Prompt auditing lives in the separate claude-code-elastic-audit
# stack, not here.  5) render .mcp.json (project-scoped Elasticsearch MCP
# server, interactive-approval). Steps 1-3 idempotent; steps 4-5 are
# create-if-absent. Override endpoints with -EsUrl / -KibanaUrl. Verification
# (smoke-test.sh) stays separate.

[CmdletBinding()]
param(
    [string]$EsUrl,
    [string]$KibanaUrl
)

$ErrorActionPreference = 'Stop'
$OtlpEndpoint = 'http://localhost:8200'
$StackDir = Split-Path -Parent $PSScriptRoot
$C = Join-Path $PSScriptRoot '../../../components'

$es = @{}; if ($EsUrl)     { $es['EsUrl'] = $EsUrl }
$kb = @{}; if ($KibanaUrl) { $kb['KibanaUrl'] = $KibanaUrl }

function Invoke-Step {
    param([string]$Label, [string]$Path, [hashtable]$StepArgs)
    Write-Host "[setup] $Label"
    $global:LASTEXITCODE = 0
    & $Path @StepArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Invoke-Step -Label '1/5 - trace-routing ingest pipeline' -Path (Join-Path $C 'backends/elastic/scripts/setup-trace-routing.ps1') -StepArgs $es
Invoke-Step -Label '2/5 - prompts-audit index' -Path (Join-Path $C 'backends/elastic/scripts/setup-prompt-audit.ps1') -StepArgs $es
$kb['Sources'] = @('claude-code')
Invoke-Step -Label '3/5 - Kibana saved objects' -Path (Join-Path $C 'backends/elastic/scripts/import-kibana-objects.ps1') -StepArgs $kb
Invoke-Step -Label '4/5 - local Claude Code settings (telemetry env)' `
    -Path (Join-Path $C 'agents/claude-code/scripts/render-otel.ps1') `
    -StepArgs @{ TargetDir = $StackDir; LogsEndpoint = "$OtlpEndpoint/v1/logs"; TracesEndpoint = "$OtlpEndpoint/v1/traces"; MetricsEndpoint = "$OtlpEndpoint/v1/metrics" }
Invoke-Step -Label '5/5 - local Claude Code MCP config (.mcp.json)' `
    -Path (Join-Path $C 'agents/claude-code/scripts/render-mcp.ps1') `
    -StepArgs @{ TargetDir = $StackDir }

Write-Host "[setup] done - run 'claude' from this directory; verify with scripts/smoke-test.sh."



