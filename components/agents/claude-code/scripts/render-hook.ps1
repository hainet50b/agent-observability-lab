[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path (Join-Path $ComponentDir 'templates') 'hook.template.json'
$Entry = Join-Path (Join-Path $ComponentDir 'hooks') 'agent-audit.ps1'

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

$out = Join-Path $TargetDir '.claude/settings.local.json'

if (Test-Path -LiteralPath $out) {
    $existing = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
    if ($existing.PSObject.Properties.Name -contains 'hooks') {
        Write-Host "kept existing hooks in $out (delete to regenerate)"
        exit 0
    }
}

New-Item -ItemType Directory -Force -Path (Join-Path $TargetDir '.claude') | Out-Null
$entryAbs = (Resolve-Path -LiteralPath $Entry).Path
$targetAbs = (Resolve-Path -LiteralPath $TargetDir).Path
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

if (Test-Path -LiteralPath $out) {
    $cfg = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName 'hooks' -NotePropertyValue $hooks -Force
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $out -Encoding utf8
    Write-Host "added hooks to $out"
}
else {
    [pscustomobject]@{ hooks = $hooks } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $out -Encoding utf8
    Write-Host "wrote $out"
}



