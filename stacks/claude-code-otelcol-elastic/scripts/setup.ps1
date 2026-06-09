#!/usr/bin/env pwsh
# setup.ps1 — one-shot bootstrap for the claude-code-otelcol-elastic stack.
#
# PowerShell mirror of setup.sh. Run once after `docker compose up -d` (healthy).
# Steps: 1) trace-routing pipeline  2) prompts-audit index  3) Kibana saved
# objects (backend, agent, sidecar)  4) render .claude/settings.local.json
# (telemetry env pointed at the Collector + audit hook) from the agent-owned
# template, so a `claude` launched from this directory auto-emits telemetry and
# audits prompts. Steps 1-3 idempotent; step 4 is create-if-absent. Override
# endpoints with -EsUrl / -KibanaUrl. Verification stays separate.

[CmdletBinding()]
param(
    [string]$EsUrl,
    [string]$KibanaUrl
)

$ErrorActionPreference = 'Stop'
$OtlpEndpoint = 'http://localhost:4318'
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

Invoke-Step '1/4 - trace-routing ingest pipeline' (Join-Path $C 'backends/elastic/scripts/setup-trace-routing.ps1') $es
Invoke-Step '2/4 - prompts-audit index'           (Join-Path $C 'backends/elastic/scripts/setup-prompt-audit.ps1')  $es
Write-Host '[setup] 3/4 - Kibana saved objects'
Invoke-Step '  backend data views' (Join-Path $C 'backends/elastic/scripts/import-kibana-objects.ps1') $kb
Invoke-Step '  agent assets'       (Join-Path $C 'agents/claude-code/scripts/import-kibana-objects.ps1') $kb
Invoke-Step '  sidecar path view'  (Join-Path $C 'paths/otelcol-sidecar/scripts/import-kibana-objects.ps1') $kb
Invoke-Step '4/4 - local Claude Code settings (telemetry env + audit hook)' `
    (Join-Path $C 'agents/claude-code/scripts/render-settings.ps1') `
    @{ OtlpEndpoint = $OtlpEndpoint; TargetDir = $StackDir }

Write-Host "[setup] done - run 'claude' here; verify with smoke-test.sh (and resilience-test.sh)."
