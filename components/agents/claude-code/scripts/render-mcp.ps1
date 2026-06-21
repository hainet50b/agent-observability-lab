[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$Endpoint
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path (Join-Path $ComponentDir 'templates') 'mcp.template.json'
. (Join-Path $ComponentDir '../shared/config-place/lib/config-place-core.ps1')

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

$out = Join-Path $TargetDir '.mcp.json'

$cfg = Get-Content -Raw -LiteralPath $Template | ConvertFrom-Json
$cfg.PSObject.Properties.Remove('_comment')

$tmp = New-TemporaryFile
try {
    ($cfg | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tmp -Encoding utf8
    Set-CpFile 'mcp' 'claude-code' $Endpoint $tmp $out
}
finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
