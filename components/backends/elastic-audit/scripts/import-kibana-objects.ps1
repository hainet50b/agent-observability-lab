#!/usr/bin/env pwsh
# import-kibana-objects.ps1 — import the elastic-audit backend's Agent Audit
# Kibana saved objects.
#
# PowerShell mirror of import-kibana-objects.sh (same pairing as ralph.sh /
# ralph.ps1). Scope: the cross-agent **Agent Audit** assets this backend owns —
# the Agent Audit data views (logs-agent_audit.user_prompt-* /
# logs-agent_audit.tool_call-*) and their saved searches. These are
# agent-cross-cutting (the AI agent is a document field, not a stream-name
# segment), so they belong to the backend, not to any single agent's import script.
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

# The Agent Audit assets this backend owns: the Agent Audit — User Prompts and
# Agent Audit — Tool Calls data views + saved searches (the cross-agent hook->ES
# audit streams logs-agent_audit.*-*). Each NDJSON is self-contained (its saved
# search's data-view reference resolves within the same file).
$Files = @(
    'kibana/agent-audit.ndjson'
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

Write-Host "[import] importing Agent Audit Kibana saved objects into $KibanaUrl…"
foreach ($f in $Files) {
    Import-File -File $f
}

Write-Host ""
Write-Host "PASS: Agent Audit Kibana objects imported into $KibanaUrl."
