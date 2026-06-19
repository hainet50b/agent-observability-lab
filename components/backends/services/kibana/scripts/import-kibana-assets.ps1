#!/usr/bin/env pwsh
# Imports the Kibana saved objects for each SOURCE in -Sources (a dir under this
# component) via the _import?overwrite=true API. Within each dir, files load in
# dependency order: data-views → saved-searches → dashboard. PowerShell 7+;
# -KibanaUrl or KIBANA_URL env overrides the base URL.

[CmdletBinding()]
param(
    [string]$KibanaUrl = $(if ($env:KIBANA_URL) { $env:KIBANA_URL } else { 'http://localhost:5601' }),
    [Parameter(Mandatory = $true)]
    [string[]]$Sources
)

$ErrorActionPreference = 'Stop'

# component root; per-source paths are built absolutely from it (no Set-Location — it would park the caller's shell here)
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir

function Import-File {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error "FAIL: $Path not found"
        exit 1
    }
    $rel = [System.IO.Path]::GetRelativePath($ComponentDir, $Path)
    Write-Host "[import] $rel"

    try {
        $result = Invoke-RestMethod -Method Post `
            -Uri "$KibanaUrl/api/saved_objects/_import?overwrite=true" `
            -Headers @{ 'kbn-xsrf' = 'true' } `
            -Form @{ file = Get-Item -LiteralPath $Path }
    }
    catch {
        Write-Error "FAIL: request to Kibana failed for $rel ($_)"
        exit 1
    }

    $result | ConvertTo-Json -Depth 10 | Write-Host

    if (-not $result.success) {
        Write-Error "FAIL: $rel did not import cleanly (success=$($result.success))"
        exit 1
    }
    Write-Host "[import] $rel -> $($result.successCount) object(s) imported"
}

# data-views → saved-searches → dashboard; missing categories are skipped.
function Import-Dir {
    param([string]$Dir)

    $Full = Join-Path $ComponentDir $Dir
    if (-not (Test-Path -LiteralPath $Full)) {
        Write-Error "FAIL: $Dir not found"
        exit 1
    }
    foreach ($category in 'data-views', 'saved-searches', 'dashboard') {
        Get-ChildItem -LiteralPath $Full -Filter "*$category.ndjson" -File |
            Sort-Object Name | ForEach-Object { Import-File -Path $_.FullName }
    }
}

Write-Host "[import] importing Kibana saved objects into $KibanaUrl…"

foreach ($src in $Sources) {
    Import-Dir -Dir "$src"
}

Write-Host ""
Write-Host "PASS: Kibana saved objects imported into $KibanaUrl (sources: $($Sources -join ', '))."
Write-Host "Open Discover (Open menu) for the saved searches, or the data-view selector"
Write-Host "for the Metrics / Events / Traces views."
