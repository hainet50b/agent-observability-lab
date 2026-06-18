#!/usr/bin/env pwsh
# render-hook.ps1 — register the Claude Code prompt-capture audit hook in
# <TargetDir>/.claude/settings.local.json (PowerShell mirror of render-hook.sh).
#
# Merges the `hooks` block from ../hook.template.json into the target's
# settings.local.json, substituting @@HOOK_COMMAND@@ with THIS platform's
# capture-prompt.ps1 absolute path plus `--config <abs>/.claude/agent-audit.conf`
# (the config path is INJECTED into the hook command — a shipped hook never
# discovers its own config; see SPEC/agent-audit.md "Delivery and authorization").
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
$hookCmd = "$captureAbs --config $conf"

# Substitute @@HOOK_COMMAND@@ in the template's fixed hook path, then take the
# `hooks` block (dropping the template's _comment).
$tpl = Get-Content -Raw -LiteralPath $Template | ConvertFrom-Json
$tpl.hooks.UserPromptSubmit[0].hooks[0].command = $hookCmd
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

