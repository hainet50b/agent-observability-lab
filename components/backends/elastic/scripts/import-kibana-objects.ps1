#!/usr/bin/env pwsh
# import-kibana-objects.ps1 — the Elastic backend's single Kibana saved-objects
# importer for every source (agent / path).
#
# PowerShell mirror of import-kibana-objects.sh (same pairing as ralph.sh /
# ralph.ps1). Kibana objects are consumed by Kibana, a backend service, so all
# per-source NDJSON lives under this backend, namespaced by source:
# kibana/<source>/ (e.g. kibana/claude-code/, kibana/codex-cli/,
# kibana/otelcol-sidecar/). The cross-agent objects that per-agent saved searches
# depend on (e.g. the AI Agents — Traces data view) live in kibana/cross-agent/.
#
# Pass the source namespace(s) to import via -Sources. The cross-agent objects
# are always imported first so per-agent references resolve; within every
# directory files import in category order data-views → saved-searches →
# dashboard, so data views exist before the saved searches and dashboards that
# reference them.
#
# Prerequisites: PowerShell 7+ (curl is not required — uses Invoke-RestMethod).
# Override the Kibana base URL with -KibanaUrl or the KIBANA_URL env var
# (default below).
#
#   ./scripts/import-kibana-objects.ps1 -Sources claude-code
#   ./scripts/import-kibana-objects.ps1 -Sources claude-code,otelcol-sidecar
#   ./scripts/import-kibana-objects.ps1 -KibanaUrl http://localhost:5601 -Sources codex-cli
#
# Run from anywhere — it locates its own component directory like the .sh version.

[CmdletBinding()]
param(
    [string]$KibanaUrl = $(if ($env:KIBANA_URL) { $env:KIBANA_URL } else { 'http://localhost:5601' }),
    [Parameter(Mandatory = $true)]
    [string[]]$Sources
)

$ErrorActionPreference = 'Stop'

# Resolve the component root (parent of this scripts/ directory). Paths into
# kibana/ are built absolutely from it (see Import-File) so they resolve
# regardless of the caller's cwd — without Set-Location, which runs in the
# caller's PowerShell session and would leave their shell parked here.
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

# Import every NDJSON in a directory in dependency category order: data views
# before the saved searches and dashboards that reference them. Missing
# categories are skipped silently (not every source ships all three).
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

# Cross-agent objects first (e.g. the AI Agents — Traces data view) so per-agent
# saved searches that reference them resolve.
Import-Dir -Dir 'kibana/cross-agent'

# Then each requested source namespace.
foreach ($src in $Sources) {
    Import-Dir -Dir "kibana/$src"
}

Write-Host ""
Write-Host "PASS: Kibana saved objects imported into $KibanaUrl (sources: $($Sources -join ', '))."
Write-Host "Open Discover (Open menu) for the saved searches, or the data-view selector"
Write-Host "for the Metrics / Events / Traces views."

