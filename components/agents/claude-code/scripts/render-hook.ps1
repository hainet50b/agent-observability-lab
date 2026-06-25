[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$Endpoint
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path (Join-Path $ComponentDir 'templates') 'hook.template.json'
$HooksSrc = Join-Path $ComponentDir 'hooks'
$CoreSrc = Join-Path $ComponentDir '../shared/agent-audit/lib'
. (Join-Path $ComponentDir '../shared/config-place/lib/config-place-core.ps1')

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

$out = Join-Path $TargetDir '.claude/settings.local.json'

Test-CpOursOrAbsent 'hook' $Endpoint $out | Out-Null

New-Item -ItemType Directory -Force -Path (Join-Path $TargetDir '.claude') | Out-Null
$targetAbs = (Resolve-Path -LiteralPath $TargetDir).Path

$hooksDst = Join-Path $targetAbs '.claude/hooks'
New-Item -ItemType Directory -Force -Path (Join-Path $hooksDst 'lib') | Out-Null
Copy-Item -LiteralPath (Join-Path $HooksSrc 'agent-audit.sh'), (Join-Path $HooksSrc 'agent-audit.ps1') -Destination $hooksDst -Force
Copy-Item -LiteralPath (Join-Path $HooksSrc 'lib/adapter.sh'), (Join-Path $HooksSrc 'lib/adapter.ps1') -Destination (Join-Path $hooksDst 'lib') -Force
Copy-Item -LiteralPath (Join-Path $CoreSrc 'agent-audit-core.sh'), (Join-Path $CoreSrc 'agent-audit-core.ps1') -Destination (Join-Path $hooksDst 'lib') -Force
Copy-Item -LiteralPath (Join-Path $CoreSrc 'seal.sh'), (Join-Path $CoreSrc 'seal.ps1') -Destination (Join-Path $hooksDst 'lib') -Force
$entryAbs = Join-Path $hooksDst 'agent-audit.ps1'
$conf = Join-Path $targetAbs '.claude/agent-audit.conf'

# Exec form (command=powershell + args) is required on Windows: a command-string
# hook runs via Git Bash, which can't execute a .ps1 and fail-opens (exit 127).
$tpl = Get-Content -Raw -LiteralPath $Template | ConvertFrom-Json
foreach ($h in @(
        @{ entry = $tpl.hooks.UserPromptSubmit[0].hooks[0]; stream = 'user_prompt' },
        @{ entry = $tpl.hooks.PostToolUse[0].hooks[0]; stream = 'tool_call' }
    )) {
    $h.entry.command = 'powershell'
    $h.entry | Add-Member -NotePropertyName 'args' -NotePropertyValue @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $entryAbs, '-Stream', $h.stream, '-Config', $conf
    ) -Force
}
$hooks = $tpl.hooks

# Merge our .hooks into the existing settings.local.json, preserving any other
# top-level keys (e.g. .env placed by the telemetry concern sharing this home).
$merged = if (Test-Path -LiteralPath $out -PathType Leaf) {
    Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
}
else {
    [pscustomobject]@{}
}
$merged | Add-Member -NotePropertyName 'hooks' -NotePropertyValue $hooks -Force

$tmp = [System.IO.Path]::GetTempFileName()
try {
    ($merged | ConvertTo-Json -Depth 12) |
        Set-Content -LiteralPath $tmp -Encoding utf8
    Set-CpFile 'hook' 'claude-code' $Endpoint $tmp $out
    Set-CpSelfIgnore 'claude-code' $Endpoint (Join-Path $targetAbs '.claude')
}
finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
