#!/usr/bin/env pwsh
# import-kibana-objects.ps1 — import the Elastic backend's cross-agent Kibana
# saved objects.
#
# PowerShell mirror of import-kibana-objects.sh (same pairing as ralph.sh /
# ralph.ps1). Scope: **cross-agent backend assets only** — agent-specific assets
# (per-agent data views, saved searches, dashboards) are imported by each agent's
# own import script (e.g. components/agents/claude-code/scripts/import-kibana-objects.ps1).
# A stack composes the two by running this script first, then the agent's.
#
# Imports the NDJSON files in ../kibana/ through the Kibana Saved Objects
# `_import?overwrite=true` API. Prints the per-file import result.
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

# The cross-agent data view this backend owns (AI Agents — Traces,
# traces-apm-agents_*). Agent-specific data views / saved searches / dashboards
# are imported by the agent's own import script.
$Files = @(
    'kibana/agents-data-views.ndjson'
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

Write-Host "[import] importing Kibana saved objects into $KibanaUrl…"
foreach ($f in $Files) {
    Import-File -File $f
}

Write-Host ""
Write-Host "PASS: backend cross-agent Kibana objects imported into $KibanaUrl."
