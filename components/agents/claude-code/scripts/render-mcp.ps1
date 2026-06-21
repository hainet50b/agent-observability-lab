[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path (Join-Path $ComponentDir 'templates') 'mcp.template.json'

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


