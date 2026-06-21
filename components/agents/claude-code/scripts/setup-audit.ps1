[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$EsUrl,
    [AllowEmptyString()][string]$ApiKey = '',
    [Parameter(Mandatory = $true)][string]$TimeoutMs,
    [Parameter(Mandatory = $true)][string]$UserPromptEnabled,
    [Parameter(Mandatory = $true)][string]$UserPromptContent,
    [Parameter(Mandatory = $true)][string]$ToolCallEnabled,
    [Parameter(Mandatory = $true)][string]$ToolCallContent,
    [string]$MarkerEndpoint = ''
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath

# Ownership marker endpoint. Defaults to the audit ES URL (the lab's single-
# concern behaviour); a caller sharing one home across concerns passes a unified
# value so every bundle file carries the same marker.
$Marker = if ($MarkerEndpoint) { $MarkerEndpoint } else { $EsUrl }

& (Join-Path $ScriptDir 'render-hook.ps1') -TargetDir $TargetDir -Endpoint $Marker
& (Join-Path $ScriptDir 'render-agent-audit.ps1') -EsUrl $EsUrl -TargetDir $TargetDir `
    -ApiKey $ApiKey -TimeoutMs $TimeoutMs `
    -UserPromptEnabled $UserPromptEnabled -UserPromptContent $UserPromptContent `
    -ToolCallEnabled $ToolCallEnabled -ToolCallContent $ToolCallContent -MarkerEndpoint $Marker
