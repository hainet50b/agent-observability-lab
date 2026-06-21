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
$HooksSrc = Join-Path $ComponentDir 'hooks'
$CoreSrc = Join-Path $ComponentDir '../shared/agent-audit/lib'
$Template = Join-Path (Join-Path $ComponentDir 'templates') 'hooks.template.toml'

foreach ($h in @((Join-Path $HooksSrc 'agent-audit.sh'), (Join-Path $HooksSrc 'agent-audit.ps1'))) {
    if (-not (Test-Path -LiteralPath $h -PathType Leaf)) {
        Write-Error "FAIL: hook not found: $h"
        exit 1
    }
}
if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

New-Item -ItemType Directory -Force -Path (Join-Path $TargetDir '.codex') | Out-Null
$targetAbs = (Resolve-Path -LiteralPath $TargetDir).Path
$hooksDst = Join-Path $targetAbs '.codex/hooks'
New-Item -ItemType Directory -Force -Path (Join-Path $hooksDst 'lib') | Out-Null
Copy-Item -LiteralPath (Join-Path $HooksSrc 'agent-audit.sh'), (Join-Path $HooksSrc 'agent-audit.ps1') -Destination $hooksDst -Force
Copy-Item -LiteralPath (Join-Path $HooksSrc 'lib/adapter.sh'), (Join-Path $HooksSrc 'lib/adapter.ps1') -Destination (Join-Path $hooksDst 'lib') -Force
Copy-Item -LiteralPath (Join-Path $CoreSrc 'agent-audit-core.sh'), (Join-Path $CoreSrc 'agent-audit-core.ps1') -Destination (Join-Path $hooksDst 'lib') -Force
$AgentAuditSh = Join-Path $hooksDst 'agent-audit.sh'
$AgentAuditPs1 = Join-Path $hooksDst 'agent-audit.ps1'

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
