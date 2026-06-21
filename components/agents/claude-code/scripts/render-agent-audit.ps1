[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EsUrl,
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [AllowEmptyString()][string]$ApiKey = '',
    [Parameter(Mandatory = $true)][string]$TimeoutMs,
    [Parameter(Mandatory = $true)][string]$UserPromptEnabled,
    [Parameter(Mandatory = $true)][string]$UserPromptContent,
    [Parameter(Mandatory = $true)][string]$ToolCallEnabled,
    [Parameter(Mandatory = $true)][string]$ToolCallContent
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path (Join-Path $ComponentDir 'templates') 'agent-audit.template.conf'

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

$config = Join-Path $TargetDir '.claude/agent-audit.conf'
if (Test-Path -LiteralPath $config) {
    Write-Host "kept existing $config (delete to regenerate)"
    exit 0
}

$content = (Get-Content -Raw -LiteralPath $Template) `
    -replace '@@ES_URL@@', $EsUrl `
    -replace '@@ES_API_KEY@@', $ApiKey `
    -replace '@@ES_TIMEOUT_MS@@', $TimeoutMs `
    -replace '@@CAPTURE_USER_PROMPT_ENABLED@@', $UserPromptEnabled `
    -replace '@@CAPTURE_USER_PROMPT_CONTENT@@', $UserPromptContent `
    -replace '@@CAPTURE_TOOL_CALL_ENABLED@@', $ToolCallEnabled `
    -replace '@@CAPTURE_TOOL_CALL_CONTENT@@', $ToolCallContent
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $config) | Out-Null
[System.IO.File]::WriteAllText($config, $content, [System.Text.UTF8Encoding]::new($false))
Write-Host "wrote $config"
