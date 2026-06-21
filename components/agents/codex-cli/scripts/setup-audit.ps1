[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$EsUrl
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath

& (Join-Path $ScriptDir 'render-agent-audit.ps1') -EsUrl $EsUrl -TargetDir $TargetDir
& (Join-Path $ScriptDir 'render-hooks.ps1') -TargetDir $TargetDir
& (Join-Path $ScriptDir 'render-mcp.ps1') -TargetDir $TargetDir

