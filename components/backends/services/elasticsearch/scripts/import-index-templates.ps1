#!/usr/bin/env pwsh
# import-index-templates.ps1 — the Elasticsearch service's generic data-stream
# index-template applier (PowerShell mirror of import-index-templates.sh).
#
# Each name in -Names is a template whose body lives at index-templates/<name>.json
# under this service component. For each, it installs the composable index template,
# creates the data stream <name>-default if absent, and syncs the template's mapping
# onto the live stream. Carries no per-backend selection — the calling backend
# passes the names its identity calls for.
#
# The mapping sync matters because a template only shapes NEW backing indices: a
# stream provisioned before a mapping change would keep the old strict mapping and
# REJECT new fields. Adding fields to a strict mapping is allowed and idempotent.
#
# Idempotent: each template PUT replaces in place; each data stream is created only
# if absent; the mapping PUT only adds fields.
#
# Prerequisites: PowerShell 7+ (uses Invoke-RestMethod). Override the Elasticsearch
# base URL with -EsUrl or the ES_URL env var (default below).
#
#   ./scripts/import-index-templates.ps1 -Names 'logs-agent_audit.user_prompt','logs-agent_audit.tool_call'
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

# Provision one template: install it, create the data stream <name>-default if
# absent, and sync the template's mapping onto the live stream.
function Invoke-Provision($Template) {
    $DataStream = "$Template-default"
    $TemplateFile = Join-Path $ComponentDir "index-templates/$Template.json"
    if (-not (Test-Path -LiteralPath $TemplateFile -PathType Leaf)) {
        Write-Error "FAIL: index template not found: $TemplateFile"; exit 1
    }
    $Body = Get-Content -Raw -LiteralPath $TemplateFile

    # 1. Install / replace the composable index template (idempotent).
    Write-Host "[apply] installing index template '$Template' on $EsUrl…"
    try {
        $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/_index_template/$Template" `
            -ContentType 'application/json' -Body $Body
    } catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
    $result | ConvertTo-Json -Depth 10 | Write-Host
    if (-not $result.acknowledged) { Write-Error "FAIL: index template PUT not acknowledged"; exit 1 }
    Write-Host "[apply] index template '$Template' installed"

    # 2. Create the data stream if it does not already exist (PUT is not idempotent).
    $exists = $false
    try {
        Invoke-RestMethod -Method Get -Uri "$EsUrl/_data_stream/$DataStream" | Out-Null
        $exists = $true
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 404) {
            Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1
        }
        # 404 — fall through to create.
    }
    if ($exists) {
        Write-Host "[apply] data stream '$DataStream' already exists — leaving as-is"
    } else {
        Write-Host "[apply] creating data stream '$DataStream' on $EsUrl…"
        try { $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/_data_stream/$DataStream" }
        catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
        $result | ConvertTo-Json -Depth 10 | Write-Host
        if (-not $result.acknowledged) { Write-Error "FAIL: data stream create not acknowledged"; exit 1 }
        Write-Host "[apply] data stream '$DataStream' created"
    }

    # 3. Sync the template's mapping onto the live data stream (forward-compatible).
    Write-Host "[apply] syncing mapping onto data stream '$DataStream'…"
    $mappings = ((Get-Content -Raw -LiteralPath $TemplateFile | ConvertFrom-Json).template.mappings | ConvertTo-Json -Depth 20)
    try {
        $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/$DataStream/_mapping" `
            -ContentType 'application/json' -Body $mappings
    } catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
    $result | ConvertTo-Json -Depth 10 | Write-Host
    if (-not $result.acknowledged) { Write-Error "FAIL: data stream mapping update not acknowledged"; exit 1 }
    Write-Host "[apply] mapping synced onto '$DataStream'"
    Write-Host ""
}

foreach ($name in $Names) { Invoke-Provision $name }

Write-Host "PASS: index template(s) + data stream(s) applied on $EsUrl`: $($Names -join ', ')."

