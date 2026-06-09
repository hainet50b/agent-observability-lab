#!/usr/bin/env pwsh
# render-settings.ps1 — render the Claude Code agent's settings.local.json
# (PowerShell mirror of render-settings.sh; writes the PowerShell hook form).
#
# The settings content lives once in the agent-owned template
# ../settings.template.json. This fills the three non-agent values — the stack's
# OTLP endpoint, the audit-store endpoint, and this machine's absolute hook
# command (powershell -File <abs capture-prompt.ps1>) — into
# <TargetDir>/.claude/settings.local.json. Uses built-in JSON cmdlets (no deps).
#
# create-if-absent: an existing settings.local.json is left untouched.
#
# Usage: render-settings.ps1 -OtlpEndpoint <url> -TargetDir <dir> [-AuditUrl <url>]

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OtlpEndpoint,
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [string]$AuditUrl
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path $ComponentDir 'settings.template.json'
if (-not $AuditUrl) { $AuditUrl = if ($env:PROMPTS_AUDIT_ES_URL) { $env:PROMPTS_AUDIT_ES_URL } else { 'http://localhost:9200' } }

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

$out = Join-Path $TargetDir '.claude/settings.local.json'
if (Test-Path -LiteralPath $out) {
    Write-Host "kept existing $out (delete to regenerate)"
    exit 0
}

$Hook = (Resolve-Path (Join-Path $ComponentDir 'hooks/capture-prompt.ps1')).Path
$cfg = Get-Content -Raw -LiteralPath $Template | ConvertFrom-Json
$cfg.env.OTEL_EXPORTER_OTLP_ENDPOINT = $OtlpEndpoint
$cfg.env.PROMPTS_AUDIT_ES_URL = $AuditUrl
$cfg.hooks.UserPromptSubmit[0].hooks[0].command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$Hook`""

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null
$cfg | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $out -Encoding utf8

Write-Host "wrote $out"
