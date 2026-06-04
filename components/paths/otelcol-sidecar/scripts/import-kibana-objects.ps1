#!/usr/bin/env pwsh
# import-kibana-objects.ps1 — import the otelcol-sidecar path's Kibana saved objects.
#
# PowerShell mirror of import-kibana-objects.sh (same pairing as ralph.sh /
# ralph.ps1). Scope: the **path** component assets — the sidecar self-telemetry
# data view (OTel Collector Sidecar — Metrics, on metrics-apm.app.otelcol_sidecar*).
# The sidecar emits only metrics, so there are no saved searches; the
# visualization surface is the Health dashboard. A stack that includes this path
# composes the imports by running the backend's import, then the agent's, then
# this one.
#
# Imports the NDJSON files in ../kibana/ through the Kibana Saved Objects
# `_import?overwrite=true` API. The data view has no cross-references, so a single
# file is enough today; later assets (e.g. the Health dashboard) append to $Files
# after the data view it references. Prints the per-file import result.
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

# Data views first — any later asset (Health dashboard) that references the
# otelcol-sidecar-metrics data view must find it already imported.
$Files = @(
    'kibana/data-views.ndjson'
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

Write-Host "[import] importing otelcol-sidecar Kibana saved objects into $KibanaUrl…"
foreach ($f in $Files) {
    Import-File -File $f
}

Write-Host ""
Write-Host "PASS: otelcol-sidecar Kibana saved objects imported. Open Discover and pick the"
Write-Host "OTel Collector Sidecar — Metrics data view to inspect the otelcol_* self-metrics."
