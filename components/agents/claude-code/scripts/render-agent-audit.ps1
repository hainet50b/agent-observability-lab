[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EsUrl,
    [Parameter(Mandatory = $true)][string]$TargetDir,
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
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path (Join-Path $ComponentDir 'templates') 'agent-audit.template.conf'
. (Join-Path $ComponentDir '../shared/config-place/lib/config-place-core.ps1')

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

# Ownership marker endpoint. Defaults to the audit ES URL (the conf's data value
# stays the ES URL regardless); a caller sharing one home across concerns passes
# a unified value so every bundle file carries the same marker.
$Marker = if ($MarkerEndpoint) { $MarkerEndpoint } else { $EsUrl }

$config = Join-Path $TargetDir '.claude/agent-audit.conf'

$content = (Get-Content -Raw -LiteralPath $Template) `
    -replace '@@ES_URL@@', $EsUrl `
    -replace '@@ES_API_KEY@@', $ApiKey `
    -replace '@@ES_TIMEOUT_MS@@', $TimeoutMs `
    -replace '@@CAPTURE_USER_PROMPT_ENABLED@@', $UserPromptEnabled `
    -replace '@@CAPTURE_USER_PROMPT_CONTENT@@', $UserPromptContent `
    -replace '@@CAPTURE_TOOL_CALL_ENABLED@@', $ToolCallEnabled `
    -replace '@@CAPTURE_TOOL_CALL_CONTENT@@', $ToolCallContent

$tmp = New-TemporaryFile
try {
    [System.IO.File]::WriteAllText($tmp, $content, [System.Text.UTF8Encoding]::new($false))
    Set-CpFile 'agent-audit' 'claude-code' $Marker $tmp $config
    Set-CpSelfIgnore 'claude-code' $Marker (Join-Path $TargetDir '.claude')
}
finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
