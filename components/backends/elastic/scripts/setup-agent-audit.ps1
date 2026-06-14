#!/usr/bin/env pwsh
# setup-agent-audit.ps1 — provision the Agent Audit user-prompt data stream.
#
# PowerShell mirror of setup-agent-audit.sh (same pairing as the other
# setup-*/import-* script pairs). See that file's header for the full rationale:
# direct agent-audit user-prompt records live in a dedicated, agent-cross-cutting
# Elasticsearch log data stream (SPEC/agent-audit.md), separate from OTLP/APM
# telemetry. The AI agent is a document field (agent_audit.agent.*), not a segment
# of the stream name, so this is backend-owned. The mapping is the single source of
# truth in elasticsearch/agent-audit.user_prompt.template.json.
#
# Creates the composable index template `logs-agent_audit.user_prompt` (strict
# mappings, priority 200, 30-day data-stream lifecycle) and the data stream
# `logs-agent_audit.user_prompt-default`.
#
# Idempotent: the template PUT replaces in place; the data stream is created only
# if absent.
#
# Prerequisites: PowerShell 7+ (uses Invoke-RestMethod). Override the
# Elasticsearch base URL with -EsUrl or the ES_URL env var (default below).
#
#   ./scripts/setup-agent-audit.ps1
#   ./scripts/setup-agent-audit.ps1 -EsUrl http://localhost:9200
#
# Run from anywhere — it locates its own component directory like the .sh version.

[CmdletBinding()]
param(
    [string]$EsUrl = $(if ($env:ES_URL) { $env:ES_URL } else { 'http://localhost:9200' })
)

$ErrorActionPreference = 'Stop'
$Template = 'logs-agent_audit.user_prompt'
$DataStream = 'logs-agent_audit.user_prompt-default'

# Resolve the component root (parent of this scripts/ directory) and build the
# template path absolutely from it, so it resolves regardless of the caller's cwd.
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$TemplateFile = Join-Path $ComponentDir 'elasticsearch/agent-audit.user_prompt.template.json'

if (-not (Test-Path -LiteralPath $TemplateFile -PathType Leaf)) {
    Write-Error "FAIL: index template not found: $TemplateFile"
    exit 1
}

$Body = Get-Content -Raw -LiteralPath $TemplateFile

# 1. Install / replace the composable index template (idempotent).
Write-Host "[setup] installing index template '$Template' on $EsUrl…"
try {
    $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/_index_template/$Template" `
        -ContentType 'application/json' -Body $Body
}
catch {
    Write-Error "FAIL: request to Elasticsearch failed ($_)"
    exit 1
}
$result | ConvertTo-Json -Depth 10 | Write-Host
if (-not $result.acknowledged) {
    Write-Error "FAIL: index template PUT not acknowledged"
    exit 1
}
Write-Host "[setup] index template '$Template' installed"

# 2. Create the data stream if it does not already exist (PUT is not idempotent).
$exists = $false
try {
    Invoke-RestMethod -Method Get -Uri "$EsUrl/_data_stream/$DataStream" | Out-Null
    $exists = $true
}
catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 404) {
        Write-Error "FAIL: request to Elasticsearch failed ($_)"
        exit 1
    }
    # 404 — fall through to create.
}

if ($exists) {
    Write-Host "[setup] data stream '$DataStream' already exists — leaving as-is"
}
else {
    Write-Host "[setup] creating data stream '$DataStream' on $EsUrl…"
    try {
        $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/_data_stream/$DataStream"
    }
    catch {
        Write-Error "FAIL: request to Elasticsearch failed ($_)"
        exit 1
    }
    $result | ConvertTo-Json -Depth 10 | Write-Host
    if (-not $result.acknowledged) {
        Write-Error "FAIL: data stream create not acknowledged"
        exit 1
    }
    Write-Host "[setup] data stream '$DataStream' created"
}

# 3. Sync the template's mapping onto the live data stream. The template only
# shapes NEW backing indices, so a stream provisioned before a mapping change
# (e.g. the host.* fields) would keep the old strict mapping and REJECT the new
# fields — silent loss on a fail-open hook. Adding fields to a strict mapping is
# allowed and idempotent, so PUT the template's mappings to the stream every run.
Write-Host "[setup] syncing mapping onto data stream '$DataStream'…"
$mappings = ((Get-Content -Raw -LiteralPath $TemplateFile | ConvertFrom-Json).template.mappings | ConvertTo-Json -Depth 20)
try {
    $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/$DataStream/_mapping" `
        -ContentType 'application/json' -Body $mappings
}
catch {
    Write-Error "FAIL: request to Elasticsearch failed ($_)"
    exit 1
}
$result | ConvertTo-Json -Depth 10 | Write-Host
if (-not $result.acknowledged) {
    Write-Error "FAIL: data stream mapping update not acknowledged"
    exit 1
}
Write-Host "[setup] mapping synced onto '$DataStream'"

Write-Host ""
Write-Host "PASS: Agent Audit store '$DataStream' ready on $EsUrl (strict mapping,"
Write-Host "30-day retention). The UserPromptSubmit hook indexes one document per"
Write-Host "submitted prompt here, independent of the OTLP/APM pipeline."
