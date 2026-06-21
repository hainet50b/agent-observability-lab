[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$EsUrl,
    [AllowEmptyString()][string]$ApiKey = '',
    [Parameter(Mandatory = $true)][string]$TimeoutMs,
    [Parameter(Mandatory = $true)][string]$UserPromptEnabled,
    [Parameter(Mandatory = $true)][string]$UserPromptContent,
    [Parameter(Mandatory = $true)][string]$ToolCallEnabled,
    [Parameter(Mandatory = $true)][string]$ToolCallContent
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath

& (Join-Path $ScriptDir 'render-agent-audit.ps1') -EsUrl $EsUrl -TargetDir $TargetDir `
    -ApiKey $ApiKey -TimeoutMs $TimeoutMs `
    -UserPromptEnabled $UserPromptEnabled -UserPromptContent $UserPromptContent `
    -ToolCallEnabled $ToolCallEnabled -ToolCallContent $ToolCallContent
& (Join-Path $ScriptDir 'render-hooks.ps1') -TargetDir $TargetDir
& (Join-Path $ScriptDir 'render-mcp.ps1') -TargetDir $TargetDir
