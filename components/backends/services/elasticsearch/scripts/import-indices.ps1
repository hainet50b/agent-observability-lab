#!/usr/bin/env pwsh
# import-indices.ps1 — the Elasticsearch service's generic concrete-index applier
# (PowerShell mirror of import-indices.sh).
#
# Each name in -Names is an index whose mapping lives at indices/<name>.json under
# this service component; the index is created from it if it does not already
# exist. Carries no per-backend selection — the calling backend passes the names
# its identity calls for.
#
# Idempotent: a create-index PUT is NOT idempotent, so an existing index is left
# untouched (we check first rather than blindly PUT).
#
# Prerequisites: PowerShell 7+ (uses Invoke-RestMethod). Override the Elasticsearch
# base URL with -EsUrl or the ES_URL env var (default below).
#
#   ./scripts/import-indices.ps1 -Names 'prompts-audit'
#
# Run from anywhere — it locates its own component dir like the .sh version.

[CmdletBinding()]
param(
    [string]$EsUrl = $(if ($env:ES_URL) { $env:ES_URL } else { 'http://localhost:9200' }),
    [Parameter(Mandatory = $true)]
    [string[]]$Names
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir

foreach ($name in $Names) {
    $file = Join-Path $ComponentDir "indices/$name.json"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Write-Error "FAIL: index mapping not found: $file"
        exit 1
    }

    # Already there? Leave it untouched (idempotent).
    try {
        Invoke-RestMethod -Method Head -Uri "$EsUrl/$name" | Out-Null
        Write-Host "[apply] index '$name' already exists — leaving as-is"
        continue
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 404) {
            Write-Error "FAIL: request to Elasticsearch failed ($_)"
            exit 1
        }
        # 404 — fall through to create.
    }

    $Body = Get-Content -Raw -LiteralPath $file
    Write-Host "[apply] creating index '$name' on $EsUrl…"
    try {
        $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/$name" `
            -ContentType 'application/json' -Body $Body
    }
    catch {
        Write-Error "FAIL: request to Elasticsearch failed ($_)"
        exit 1
    }
    $result | ConvertTo-Json -Depth 10 | Write-Host
    if (-not $result.acknowledged) {
        Write-Error "FAIL: index create not acknowledged"
        exit 1
    }
    Write-Host "[apply] index '$name' created"
}

Write-Host ""
Write-Host "PASS: index/indices applied on $EsUrl`: $($Names -join ', ')."

