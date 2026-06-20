# render-mcp.ps1 — materialize the Claude Code agent's project-scoped MCP config
# at <TargetDir>/.mcp.json from ../mcp.template.json (mirror of render-mcp.sh).
#
# Writes the agent-owned MCP server definitions verbatim — dropping only the
# _comment — to the target's .mcp.json, so a `claude` launched from <TargetDir>
# discovers the project-scoped Elasticsearch MCP server. No placeholder
# substitution (the template is self-contained). No auto-approve key: the
# server stays interactive-approval (a user decision). Uses built-in JSON
# cmdlets (no deps).
#
# create-if-absent: an existing .mcp.json is left untouched.
#
# Usage: render-mcp.ps1 -TargetDir <dir>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path $ComponentDir 'mcp.template.json'

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

$out = Join-Path $TargetDir '.mcp.json'
if (Test-Path -LiteralPath $out) {
    Write-Host "kept existing $out (delete to regenerate)"
    exit 0
}

$cfg = Get-Content -Raw -LiteralPath $Template | ConvertFrom-Json
$cfg.PSObject.Properties.Remove('_comment')

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null
$cfg | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $out -Encoding utf8
Write-Host "wrote $out"
