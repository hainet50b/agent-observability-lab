[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir
)

$ErrorActionPreference = 'Stop'

$config = Join-Path $TargetDir '.codex/config.toml'
$AgentAuditConf = Join-Path (Join-Path $TargetDir '.codex') 'agent-audit.conf'

if ((Test-Path -LiteralPath $config) -and (Select-String -LiteralPath $config -SimpleMatch '[[hooks.UserPromptSubmit]]' -Quiet)) {
    Write-Host "Skipped: $config already has [[hooks.UserPromptSubmit]]"
    exit 0
}

$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$HooksDir = Join-Path $ComponentDir 'hooks'
$AgentAuditSh = Join-Path $HooksDir 'agent-audit.sh'
$AgentAuditPs1 = Join-Path $HooksDir 'agent-audit.ps1'
$Template = Join-Path (Join-Path $ComponentDir 'templates') 'hooks.template.toml'

foreach ($h in @($AgentAuditSh, $AgentAuditPs1)) {
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
Replace('@@AGENT_AUDIT_SH@@', $AgentAuditSh).
Replace('@@AGENT_AUDIT_PS1@@', $AgentAuditPs1).
Replace('@@AGENT_AUDIT_CONF@@', $AgentAuditConf)

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $config) | Out-Null
if (Test-Path -LiteralPath $config) {
    $existing = ((Get-Content -Raw -LiteralPath $config) -replace "`r`n", "`n").TrimEnd("`n")
    $combined = $existing + "`n`n" + $block
} else {
    $combined = $block
}
[System.IO.File]::WriteAllText($config, $combined, [System.Text.UTF8Encoding]::new($false))

