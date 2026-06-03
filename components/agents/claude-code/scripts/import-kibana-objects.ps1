#!/usr/bin/env pwsh
# import-kibana-objects.ps1 — import the Claude Code agent's Kibana saved objects.
#
# PowerShell mirror of import-kibana-objects.sh (same pairing as ralph.sh /
# ralph.ps1). Scope: the Claude Code **agent** assets — its per-agent data views
# (Metrics / Events / Traces), saved searches, and the Overview dashboard. The
# cross-agent backend data view (AI Agents — Traces) is imported separately by the
# Elastic backend's own import script; a stack composes the two by running the
# backend's import first, then this one.
#
# Imports the NDJSON files in ../kibana/ through the Kibana Saved Objects
# `_import?overwrite=true` API, in dependency order: **data views first**, so the
# `cce-claude-code-events` / `cce-claude-code-metrics` / `cce-claude-code-traces`
# references in the saved searches and the dashboard resolve, then the **saved
# searches**, then the **dashboard**. Prints the per-file import result.
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

# Resolve and enter the component root (parent of this scripts/ directory) so the
# kibana/ NDJSON paths resolve regardless of the caller's cwd.
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
Set-Location -LiteralPath $ComponentDir

# Data views BEFORE saved searches BEFORE the dashboard — the saved searches and
# the dashboard reference the data views (cce-claude-code-events /
# cce-claude-code-metrics / cce-claude-code-traces), and those references must
# already exist.
$Files = @(
    'kibana/data-views.ndjson'
    'kibana/saved-searches.ndjson'
    'kibana/dashboard.ndjson'
)

function Import-File {
    param([string]$File)

    if (-not (Test-Path -LiteralPath $File)) {
        Write-Error "FAIL: $File not found"
        exit 1
    }
    Write-Host "[import] $File"

    try {
        $result = Invoke-RestMethod -Method Post `
            -Uri "$KibanaUrl/api/saved_objects/_import?overwrite=true" `
            -Headers @{ 'kbn-xsrf' = 'true' } `
            -Form @{ file = Get-Item -LiteralPath $File }
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

Write-Host "[import] importing Claude Code Kibana saved objects into $KibanaUrl…"
foreach ($f in $Files) {
    Import-File -File $f
}

Write-Host ""
Write-Host "PASS: Claude Code Kibana saved objects imported. Open Discover (Open menu) to"
Write-Host "use the saved searches, or the data-view selector for the Metrics / Events views."
