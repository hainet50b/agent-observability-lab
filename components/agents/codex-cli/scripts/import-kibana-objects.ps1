#!/usr/bin/env pwsh
# import-kibana-objects.ps1 — import the Codex CLI agent's Kibana saved objects.
#
# PowerShell mirror of import-kibana-objects.sh (same pairing as ralph.sh /
# ralph.ps1). Scope: the Codex CLI **agent** assets — its per-agent data views
# (Metrics / Events / Traces) and its curated saved searches (growing per Codex
# event type). A dashboard is added as a later increment. The cross-agent backend
# data view (AI Agents — Traces) is imported separately by the Elastic backend's
# own import script; a stack composes the two by running the backend's import
# first, then this one.
#
# Imports the NDJSON files in ../kibana/ through the Kibana Saved Objects
# `_import?overwrite=true` API, **data views first** so that later saved searches
# / dashboards which reference codex-cli-events / codex-cli-metrics /
# codex-cli-traces resolve. Prints the per-file import result.
#
# Prerequisites: PowerShell 7+ (curl is not required — uses Invoke-RestMethod).
# Override the Kibana base URL with -KibanaUrl or the KIBANA_URL env var
# (default below).
#
#   ./scripts/import-kibana-objects.ps1
#   ./scripts/import-kibana-objects.ps1 -KibanaUrl http://localhost:5601
#
# Run from anywhere — it locates its own component directory like the .sh version.

[CmdletBinding()]
param(
    [string]$KibanaUrl = $(if ($env:KIBANA_URL) { $env:KIBANA_URL } else { 'http://localhost:5601' })
)

$ErrorActionPreference = 'Stop'

# Resolve the component root (parent of this scripts/ directory). Paths into
# kibana/ are built absolutely from it (see Import-File) so they resolve
# regardless of the caller's cwd — without Set-Location, which runs in the
# caller's PowerShell session and would leave their shell parked here.
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir

# Data views FIRST, then the saved searches — the saved searches reference the
# data views (codex-cli-events / codex-cli-metrics / codex-cli-traces), so those
# references must already exist when the saved searches import.
$Files = @(
    'kibana/data-views.ndjson'
    'kibana/saved-searches.ndjson'
)

function Import-File {
    param([string]$File)

    $Path = Join-Path $ComponentDir $File
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error "FAIL: $File not found"
        exit 1
    }
    Write-Host "[import] $File"

    try {
        $result = Invoke-RestMethod -Method Post `
            -Uri "$KibanaUrl/api/saved_objects/_import?overwrite=true" `
            -Headers @{ 'kbn-xsrf' = 'true' } `
            -Form @{ file = Get-Item -LiteralPath $Path }
    }
    catch {
        Write-Error "FAIL: request to Kibana failed for $File ($_)"
        exit 1
    }

    $result | ConvertTo-Json -Depth 10 | Write-Host

    if (-not $result.success) {
        Write-Error "FAIL: $File did not import cleanly (success=$($result.success))"
        exit 1
    }
    Write-Host "[import] $File -> $($result.successCount) object(s) imported"
}

Write-Host "[import] importing Codex CLI Kibana saved objects into $KibanaUrl…"
foreach ($f in $Files) {
    Import-File -File $f
}

Write-Host ""
Write-Host "PASS: Codex CLI Kibana saved objects imported. Open the data-view selector in"
Write-Host "Discover for the Metrics / Events / Traces views."
