#!/usr/bin/env pwsh
# setup.ps1 — one-shot bootstrap for the claude-code-elastic stack.
#
# PowerShell mirror of setup.sh. Run once after `docker compose up -d` (when the
# services are healthy). Performs every post-up bootstrap step in order, so you
# don't have to find and run them individually:
#   1. backend — install the trace-routing ingest pipeline
#   2. backend — create the prompts-audit index
#   3. import the Kibana saved objects (backend cross-agent view, then the
#      Claude Code agent's data views / saved searches / dashboard)
#
# Idempotent (safe to re-run). Override endpoints with -EsUrl / -KibanaUrl (or
# the ES_URL / KIBANA_URL env vars the sub-scripts read). Verification
# (smoke-test.sh) stays separate. Run from anywhere — it locates its own dir.

[CmdletBinding()]
param(
    [string]$EsUrl,
    [string]$KibanaUrl
)

$ErrorActionPreference = 'Stop'
$C = Join-Path $PSScriptRoot '../../../components'

$es = @{}; if ($EsUrl)     { $es['EsUrl'] = $EsUrl }
$kb = @{}; if ($KibanaUrl) { $kb['KibanaUrl'] = $KibanaUrl }

function Invoke-Step {
    param([string]$Label, [string]$Path, [hashtable]$Args)
    Write-Host "[setup] $Label"
    $global:LASTEXITCODE = 0          # so a success that doesn't `exit` reads as 0
    & $Path @Args
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Invoke-Step '1/3 - trace-routing ingest pipeline' (Join-Path $C 'backends/elastic/scripts/setup-trace-routing.ps1') $es
Invoke-Step '2/3 - prompts-audit index'           (Join-Path $C 'backends/elastic/scripts/setup-prompt-audit.ps1')  $es
Write-Host '[setup] 3/3 - Kibana saved objects'
Invoke-Step '  backend data views' (Join-Path $C 'backends/elastic/scripts/import-kibana-objects.ps1') $kb
Invoke-Step '  agent assets'       (Join-Path $C 'agents/claude-code/scripts/import-kibana-objects.ps1') $kb

Write-Host '[setup] done - stack bootstrapped. Verify with scripts/smoke-test.sh.'
