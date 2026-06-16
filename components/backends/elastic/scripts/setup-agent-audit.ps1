#!/usr/bin/env pwsh
# setup-agent-audit.ps1 — provision the Agent Audit data streams.
#
# PowerShell mirror of setup-agent-audit.sh (same pairing as the other
# setup-*/import-* script pairs). See that file's header for the full rationale:
# direct agent-audit records (hook-captured user prompts and tool calls) live in
# dedicated, agent-cross-cutting Elasticsearch log data streams (SPEC/agent-audit.md),
# separate from OTLP/APM telemetry. The AI agent is a document field
# (agent_audit.agent.*), not a segment of the stream name, so this is backend-owned.
# Each mapping is the single source of truth in its elasticsearch/*.template.json.
#
# Provisions two streams from their templates:
#   * logs-agent_audit.user_prompt-default (agent-audit.user_prompt.template.json)
#   * logs-agent_audit.tool_call-default   (agent-audit.tool_call.template.json)
# For each: the composable index template (strict mappings, priority 200, 30-day
# data-stream lifecycle), the data stream, and a mapping sync onto the live stream.
# Security is disabled in the lab, so no role/api-key is created; the hooks index
# via each stream's `_doc` endpoint (the production posture grants the hook
# credential a `create_doc` scope — stack/admin setup, not these scripts).
#
# Idempotent: each template PUT replaces in place; each data stream is created only
# if absent; the mapping PUT only adds fields.
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

# Resolve the component root (parent of this scripts/ directory) and build the
# template paths absolutely from it, so they resolve regardless of the caller's cwd.
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir

# Provision one Agent Audit stream: install the index template, create the data
# stream if absent, and sync the template's mapping onto the live stream.
function Invoke-Provision($Template, $DataStream, $TemplateFile) {
    if (-not (Test-Path -LiteralPath $TemplateFile -PathType Leaf)) {
        Write-Error "FAIL: index template not found: $TemplateFile"; exit 1
    }
    $Body = Get-Content -Raw -LiteralPath $TemplateFile

    # 1. Install / replace the composable index template (idempotent).
    Write-Host "[setup] installing index template '$Template' on $EsUrl…"
    try {
        $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/_index_template/$Template" `
            -ContentType 'application/json' -Body $Body
    } catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
    $result | ConvertTo-Json -Depth 10 | Write-Host
    if (-not $result.acknowledged) { Write-Error "FAIL: index template PUT not acknowledged"; exit 1 }
    Write-Host "[setup] index template '$Template' installed"

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
        Write-Host "[setup] data stream '$DataStream' already exists — leaving as-is"
    } else {
        Write-Host "[setup] creating data stream '$DataStream' on $EsUrl…"
        try { $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/_data_stream/$DataStream" }
        catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
        $result | ConvertTo-Json -Depth 10 | Write-Host
        if (-not $result.acknowledged) { Write-Error "FAIL: data stream create not acknowledged"; exit 1 }
        Write-Host "[setup] data stream '$DataStream' created"
    }

    # 3. Sync the template's mapping onto the live data stream (forward-compatible).
    Write-Host "[setup] syncing mapping onto data stream '$DataStream'…"
    $mappings = ((Get-Content -Raw -LiteralPath $TemplateFile | ConvertFrom-Json).template.mappings | ConvertTo-Json -Depth 20)
    try {
        $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/$DataStream/_mapping" `
            -ContentType 'application/json' -Body $mappings
    } catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
    $result | ConvertTo-Json -Depth 10 | Write-Host
    if (-not $result.acknowledged) { Write-Error "FAIL: data stream mapping update not acknowledged"; exit 1 }
    Write-Host "[setup] mapping synced onto '$DataStream'"
    Write-Host ""
}

Invoke-Provision 'logs-agent_audit.user_prompt' 'logs-agent_audit.user_prompt-default' `
    (Join-Path $ComponentDir 'elasticsearch/agent-audit.user_prompt.template.json')
Invoke-Provision 'logs-agent_audit.tool_call' 'logs-agent_audit.tool_call-default' `
    (Join-Path $ComponentDir 'elasticsearch/agent-audit.tool_call.template.json')

Write-Host "PASS: Agent Audit stores ready on $EsUrl (strict mappings, 30-day retention):"
Write-Host "  logs-agent_audit.user_prompt-default — one document per submitted prompt."
Write-Host "  logs-agent_audit.tool_call-default   — one document per completed tool call."
Write-Host "Both are independent of the OTLP/APM pipeline."
