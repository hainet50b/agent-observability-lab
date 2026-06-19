#!/usr/bin/env pwsh
# import-elasticsearch-assets.ps1 — the Elasticsearch service's single concern
# importer for every asset type (PowerShell mirror of import-elasticsearch-assets.sh).
#
# Each name in -Concerns is a CONCERN whose assets live at <concern>/ under this
# service component, one file per ES object, typed by filename suffix:
#   *.pipeline.json  -> PUT _ingest/pipeline/<name>                 (replace; idempotent)
#   *.template.json  -> install index template, create <name>-default data stream
#                       if absent, sync the mapping
#   *.index.json     -> create concrete index <name> if absent
# <name> is the filename minus its type suffix. Carries no per-backend selection —
# the calling backend passes the concerns its identity calls for. Mirror of the
# kibana service's import-kibana-assets.ps1 (concern-first, type by suffix).
#
# Prerequisites: PowerShell 7+ (uses Invoke-RestMethod). Override the Elasticsearch
# base URL with -EsUrl or the ES_URL env var (default below).
#
#   ./scripts/import-elasticsearch-assets.ps1 -Concerns shared,codex-cli
#
# Run from anywhere — it locates its own component dir like the .sh version.

[CmdletBinding()]
param(
    [string]$EsUrl = $(if ($env:ES_URL) { $env:ES_URL } else { 'http://localhost:9200' }),
    [Parameter(Mandatory = $true)]
    [string[]]$Concerns
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir

function Invoke-Pipeline($Name, $File) {
    $Body = Get-Content -Raw -LiteralPath $File
    Write-Host "[apply] ingest pipeline '$Name' on $EsUrl…"
    try {
        $result = Invoke-RestMethod -Method Put `
            -Uri "$EsUrl/_ingest/pipeline/$([uri]::EscapeDataString($Name))" `
            -ContentType 'application/json' -Body $Body
    }
    catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
    $result | ConvertTo-Json -Depth 10 | Write-Host
    if (-not $result.acknowledged) { Write-Error "FAIL: pipeline PUT not acknowledged"; exit 1 }
    Write-Host "[apply] ingest pipeline '$Name' installed"
}

function Invoke-Template($Template, $TemplateFile) {
    $DataStream = "$Template-default"
    $Body = Get-Content -Raw -LiteralPath $TemplateFile

    Write-Host "[apply] installing index template '$Template' on $EsUrl…"
    try {
        $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/_index_template/$Template" `
            -ContentType 'application/json' -Body $Body
    }
    catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
    $result | ConvertTo-Json -Depth 10 | Write-Host
    if (-not $result.acknowledged) { Write-Error "FAIL: index template PUT not acknowledged"; exit 1 }
    Write-Host "[apply] index template '$Template' installed"

    $exists = $false
    try {
        Invoke-RestMethod -Method Get -Uri "$EsUrl/_data_stream/$DataStream" | Out-Null
        $exists = $true
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 404) {
            Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1
        }
    }
    if ($exists) {
        Write-Host "[apply] data stream '$DataStream' already exists — leaving as-is"
    }
    else {
        Write-Host "[apply] creating data stream '$DataStream' on $EsUrl…"
        try { $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/_data_stream/$DataStream" }
        catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
        $result | ConvertTo-Json -Depth 10 | Write-Host
        if (-not $result.acknowledged) { Write-Error "FAIL: data stream create not acknowledged"; exit 1 }
        Write-Host "[apply] data stream '$DataStream' created"
    }

    Write-Host "[apply] syncing mapping onto data stream '$DataStream'…"
    $mappings = ((Get-Content -Raw -LiteralPath $TemplateFile | ConvertFrom-Json).template.mappings | ConvertTo-Json -Depth 20)
    try {
        $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/$DataStream/_mapping" `
            -ContentType 'application/json' -Body $mappings
    }
    catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
    $result | ConvertTo-Json -Depth 10 | Write-Host
    if (-not $result.acknowledged) { Write-Error "FAIL: data stream mapping update not acknowledged"; exit 1 }
    Write-Host "[apply] mapping synced onto '$DataStream'"
}

function Invoke-Index($Name, $File) {
    $exists = $false
    try {
        Invoke-RestMethod -Method Get -Uri "$EsUrl/$Name" | Out-Null
        $exists = $true
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 404) {
            Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1
        }
    }
    if ($exists) {
        Write-Host "[apply] index '$Name' already exists — leaving as-is"
        return
    }
    $Body = Get-Content -Raw -LiteralPath $File
    Write-Host "[apply] creating index '$Name' on $EsUrl…"
    try {
        $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/$Name" `
            -ContentType 'application/json' -Body $Body
    }
    catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
    $result | ConvertTo-Json -Depth 10 | Write-Host
    if (-not $result.acknowledged) { Write-Error "FAIL: index create not acknowledged"; exit 1 }
    Write-Host "[apply] index '$Name' created"
}

# Import one concern: pipelines, then templates, then indices. Missing types are
# skipped silently — a concern need not ship all three.
function Import-Concern($Concern) {
    $dir = Join-Path $ComponentDir $Concern
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Write-Error "FAIL: concern dir not found: $dir"; exit 1
    }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.pipeline.json' -File) {
        Invoke-Pipeline ($f.Name -replace '\.pipeline\.json$', '') $f.FullName
    }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.template.json' -File) {
        Invoke-Template ($f.Name -replace '\.template\.json$', '') $f.FullName
    }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.index.json' -File) {
        Invoke-Index ($f.Name -replace '\.index\.json$', '') $f.FullName
    }
}

Write-Host "[import] applying Elasticsearch assets to $EsUrl…"
foreach ($concern in $Concerns) {
    Write-Host ''
    Write-Host "[import] concern: $concern"
    Import-Concern $concern
}

Write-Host ''
Write-Host "PASS: Elasticsearch assets applied on $EsUrl`: $($Concerns -join ', ')."
