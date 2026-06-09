#!/usr/bin/env pwsh
# setup-prompt-audit.ps1 — create the `prompts-audit` Elasticsearch index.
#
# PowerShell mirror of setup-prompt-audit.sh (same pairing as the other
# setup-*/import-* script pairs). See that file's header for the full rationale:
# this creates the agent-agnostic audit store that the prompt-capture hook POSTs
# to over a path independent of the OTLP analytics pipeline. The mapping is the
# single source of truth in elasticsearch/prompts-audit.index.json.
#
# Idempotent: if the index already exists it is left as-is.
#
# Prerequisites: PowerShell 7+ (uses Invoke-RestMethod). Override the
# Elasticsearch base URL with -EsUrl or the ES_URL env var (default below).
#
#   ./scripts/setup-prompt-audit.ps1
#   ./scripts/setup-prompt-audit.ps1 -EsUrl http://localhost:9200
#
# Run from anywhere — it locates its own component directory like the .sh version.

[CmdletBinding()]
param(
    [string]$EsUrl = $(if ($env:ES_URL) { $env:ES_URL } else { 'http://localhost:9200' })
)

$ErrorActionPreference = 'Stop'
$Index = 'prompts-audit'

# Resolve the component root (parent of this scripts/ directory) and build the
# mapping path absolutely from it, so it resolves regardless of the caller's cwd
# — without Set-Location, which runs in the caller's session.
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$IndexFile = Join-Path $ComponentDir 'elasticsearch/prompts-audit.index.json'

if (-not (Test-Path -LiteralPath $IndexFile -PathType Leaf)) {
    Write-Error "FAIL: index mapping not found: $IndexFile"
    exit 1
}

# Already there? Leave it untouched (idempotent).
try {
    Invoke-RestMethod -Method Head -Uri "$EsUrl/$Index" | Out-Null
    Write-Host "[setup] index '$Index' already exists — leaving as-is"
    Write-Host "PASS: prompt-audit store '$Index' present on $EsUrl"
    exit 0
}
catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 404) {
        Write-Error "FAIL: request to Elasticsearch failed ($_)"
        exit 1
    }
    # 404 — fall through to create.
}

$Body = Get-Content -Raw -LiteralPath $IndexFile

Write-Host "[setup] creating index '$Index' on $EsUrl…"
try {
    $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/$Index" `
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

Write-Host "[setup] index '$Index' created"
Write-Host ""
Write-Host "PASS: prompt-audit store '$Index' ready on $EsUrl. Register the capture"
Write-Host "hook (see ../../agents/claude-code/hooks/ and the stack README) and submit"
Write-Host "a prompt; the document lands in '$Index', independent of the OTLP pipeline."
