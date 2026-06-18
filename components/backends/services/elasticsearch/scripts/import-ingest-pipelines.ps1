#!/usr/bin/env pwsh
# import-ingest-pipelines.ps1 — the Elasticsearch service's generic ingest-pipeline
# applier (PowerShell mirror of import-ingest-pipelines.sh).
#
# Each name in -Names is a pipeline whose body lives at ingest-pipelines/<name>.json
# under this service component; it is PUT verbatim to _ingest/pipeline/<name>.
# Carries no per-backend selection — the calling backend passes the names its
# identity calls for; the per-pipeline rationale lives in each JSON "description".
#
# Idempotent: a PUT replaces the pipeline definition, so re-running is safe.
#
# Prerequisites: PowerShell 7+ (uses Invoke-RestMethod). Override the Elasticsearch
# base URL with -EsUrl or the ES_URL env var (default below).
#
#   ./scripts/import-ingest-pipelines.ps1 -Names 'traces-apm@custom','logs-apm.app@custom'
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
    $file = Join-Path $ComponentDir "ingest-pipelines/$name.json"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Write-Error "FAIL: pipeline body not found: $file"
        exit 1
    }
    $Body = Get-Content -Raw -LiteralPath $file

    Write-Host "[apply] ingest pipeline '$name' on $EsUrl…"
    try {
        $result = Invoke-RestMethod -Method Put `
            -Uri "$EsUrl/_ingest/pipeline/$([uri]::EscapeDataString($name))" `
            -ContentType 'application/json' -Body $Body
    }
    catch {
        Write-Error "FAIL: request to Elasticsearch failed ($_)"
        exit 1
    }
    $result | ConvertTo-Json -Depth 10 | Write-Host
    if (-not $result.acknowledged) {
        Write-Error "FAIL: pipeline PUT not acknowledged"
        exit 1
    }
    Write-Host "[apply] ingest pipeline '$name' installed"
}

Write-Host ""
Write-Host "PASS: ingest pipeline(s) applied on $EsUrl`: $($Names -join ', ')."

