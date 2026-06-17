[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir
)

$ErrorActionPreference = 'Stop'

$config = Join-Path $TargetDir '.codex/config.toml'

if ((Test-Path -LiteralPath $config) -and (Select-String -LiteralPath $config -SimpleMatch '[[hooks.UserPromptSubmit]]' -Quiet)) {
    Write-Host "Skipped: $config already has [[hooks.UserPromptSubmit]]"
    exit 0
}

$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$HooksDir = Join-Path $ComponentDir 'hooks'
$UserPromptSh = Join-Path $HooksDir 'capture-user-prompt.sh'
$UserPromptPs1 = Join-Path $HooksDir 'capture-user-prompt.ps1'
$ToolCallSh = Join-Path $HooksDir 'capture-tool-call.sh'
$ToolCallPs1 = Join-Path $HooksDir 'capture-tool-call.ps1'
$Template = Join-Path (Join-Path $ComponentDir 'templates') 'hooks.template.toml'

foreach ($h in @($UserPromptSh, $UserPromptPs1, $ToolCallSh, $ToolCallPs1)) {
    if (-not (Test-Path -LiteralPath $h -PathType Leaf)) {
        Write-Error "FAIL: hook not found: $h"
        exit 1
    }
}
if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

$block = ((Get-Content -Raw -LiteralPath $Template) -replace "`r`n", "`n").
Replace('@@USER_PROMPT_SH@@', $UserPromptSh).
Replace('@@USER_PROMPT_PS1@@', $UserPromptPs1).
Replace('@@TOOL_CALL_SH@@', $ToolCallSh).
Replace('@@TOOL_CALL_PS1@@', $ToolCallPs1)

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $config) | Out-Null
if (Test-Path -LiteralPath $config) {
    $existing = ((Get-Content -Raw -LiteralPath $config) -replace "`r`n", "`n").TrimEnd("`n")
    $combined = $existing + "`n`n" + $block
} else {
    $combined = $block
}
[System.IO.File]::WriteAllText($config, $combined, [System.Text.UTF8Encoding]::new($false))

