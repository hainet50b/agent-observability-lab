#!/usr/bin/env pwsh
# import-kibana-objects.ps1 — import the claude-code-elastic Kibana saved objects.
#
# PowerShell mirror of import-kibana-objects.sh (same pairing as ralph.sh /
# ralph.ps1). Imports the NDJSON files in ../kibana/ through the Kibana Saved
# Objects `_import?overwrite=true` API, in dependency order: the **data views**
# first, so the `cce-claude-code-events` reference that every saved search points
# at resolves, then the **saved searches**. Prints the per-file import result.
#
# Prerequisites: PowerShell 7+ (curl is not required — uses Invoke-RestMethod).
# Override the Kibana base URL with -KibanaUrl or the KIBANA_URL env var
# (default below).
#
#   ./scripts/import-kibana-objects.ps1
#   ./scripts/import-kibana-objects.ps1 -KibanaUrl http://localhost:5601
#
# Run from anywhere — it locates its own stack directory like the .sh version.

[CmdletBinding()]
param(
    [string]$KibanaUrl = $(if ($env:KIBANA_URL) { $env:KIBANA_URL } else { 'http://localhost:5601' })
)

$ErrorActionPreference = 'Stop'

# Resolve and enter the stack root (parent of this scripts/ directory) so the
# kibana/ NDJSON paths resolve regardless of the caller's cwd.
$ScriptDir = Split-Path -Parent $PSCommandPath
$StackDir = Split-Path -Parent $ScriptDir
Set-Location -LiteralPath $StackDir

# Data views BEFORE saved searches — the saved searches reference the events
# data view (cce-claude-code-events) and the reference must already exist.
$Files = @(
    'kibana/claude-code-data-views.ndjson'
    'kibana/claude-code-saved-searches.ndjson'
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

Write-Host "[import] importing Kibana saved objects into $KibanaUrl…"
foreach ($f in $Files) {
    Import-File -File $f
}

Write-Host ""
Write-Host "PASS: all Kibana saved objects imported. Open Discover (Open menu) to use the"
Write-Host "saved searches, or the data-view selector for the Metrics / Events data views."
