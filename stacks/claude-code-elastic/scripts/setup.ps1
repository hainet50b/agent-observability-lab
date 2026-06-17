#!/usr/bin/env pwsh
# setup.ps1 — one-shot bootstrap for the claude-code-elastic stack.
#
# PowerShell mirror of setup.sh. Run once after `docker compose up -d` (healthy).
# Steps: 1) trace-routing pipeline  2) prompts-audit index  3) Kibana saved
# objects  4) render .claude/settings.local.json (telemetry env + audit hook)
# from the agent-owned template, so a `claude` launched from this directory
# auto-emits telemetry and audits prompts. Steps 1-3 idempotent; step 4 is
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

Invoke-Step -Label '1/4 - trace-routing ingest pipeline' -Path (Join-Path $C 'backends/elastic/scripts/setup-trace-routing.ps1') -StepArgs $es
Invoke-Step -Label '2/4 - prompts-audit index' -Path (Join-Path $C 'backends/elastic/scripts/setup-prompt-audit.ps1') -StepArgs $es
$kb['Sources'] = @('claude-code')
Invoke-Step -Label '3/4 - Kibana saved objects' -Path (Join-Path $C 'backends/elastic/scripts/import-kibana-objects.ps1') -StepArgs $kb
Invoke-Step -Label '4/4 - local Claude Code settings (telemetry env + audit hook)' `
    -Path (Join-Path $C 'agents/claude-code/scripts/render-settings.ps1') `
    -StepArgs @{ OtlpEndpoint = $OtlpEndpoint; TargetDir = $StackDir }

Write-Host "[setup] done - run 'claude' from this directory; verify with scripts/smoke-test.sh."

