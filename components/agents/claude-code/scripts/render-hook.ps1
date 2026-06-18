#!/usr/bin/env pwsh
# render-hook.ps1 — register the Claude Code prompt-capture audit hook in
# <TargetDir>/.claude/settings.local.json (PowerShell mirror of render-hook.sh).
#
# Merges the `hooks` block from ../hook.template.json into the target's
# settings.local.json, rendering the UserPromptSubmit hook in EXEC FORM so it runs
# on Windows: `command: "powershell"` with an `args` array that spawns THIS
# platform's capture-prompt.ps1 directly (no shell), passing
# `--config <abs>/.claude/agent-audit.conf` (the config path is INJECTED into the
# hook command — a shipped hook never discovers its own config; see
# SPEC/agent-audit.md "Delivery and authorization").
#
# Why exec form: Claude runs a command-STRING hook via Git Bash when present, which
# mangles the Windows backslash path and cannot execute a .ps1 (exit 127 ->
# fail-open no-op — the audit silently delivers nothing). The exec form spawns the
# executable directly, so it is Git-Bash-independent. It pins Windows PowerShell 5.1
# (`powershell.exe`, on every Windows box — no pwsh/PS7 dependency), suppresses the
# profile (-NoProfile), and runs under any execution policy (-ExecutionPolicy
# Bypass). No `shell` field — it is ignored when `args` is set. (render-hook.sh is
# unchanged: its .sh command-string runs under the default shell on macOS/Linux.)
#
# JSON key-merge, create-if-absent: writes { "hooks": {…} } when absent; adds
# `hooks` to an existing file only if it has none; never clobbers an existing
# `hooks`. Re-running is a no-op. Uses built-in JSON cmdlets (no deps).
#
# Usage: render-hook.ps1 -TargetDir <dir>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path $ComponentDir 'hook.template.json'
$Capture = Join-Path (Join-Path $ComponentDir 'hooks') 'capture-prompt.ps1'

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

$out = Join-Path $TargetDir '.claude/settings.local.json'

# Never clobber an existing hooks block (create-if-absent).
if (Test-Path -LiteralPath $out) {
    $existing = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
    if ($existing.PSObject.Properties.Name -contains 'hooks') {
        Write-Host "kept existing hooks in $out (delete to regenerate)"
        exit 0
    }
}

New-Item -ItemType Directory -Force -Path (Join-Path $TargetDir '.claude') | Out-Null
$captureAbs = (Resolve-Path -LiteralPath $Capture).Path
$targetAbs = (Resolve-Path -LiteralPath $TargetDir).Path
$conf = Join-Path $targetAbs '.claude/agent-audit.conf'

# Take the template's hook entry (preserving its `type` / `timeout`), then rewrite
# it into exec form: command = powershell, args spawn capture-prompt.ps1 directly.
# Dropping the template's _comment. The `@@HOOK_COMMAND@@` placeholder is not used
# here — exec form sets `command` + `args` rather than a single command string.
$tpl = Get-Content -Raw -LiteralPath $Template | ConvertFrom-Json
$entry = $tpl.hooks.UserPromptSubmit[0].hooks[0]
$entry.command = 'powershell'
$entry | Add-Member -NotePropertyName 'args' -NotePropertyValue @(
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $captureAbs, '--config', $conf
) -Force
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


