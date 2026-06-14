#!/usr/bin/env pwsh
# render-hooks.ps1 — write the Codex CLI agent's stack-local .codex/hooks.json
# (PowerShell mirror of render-hooks.sh).
#
# Registers the characterization hook hooks/capture-user-prompt.{sh,ps1} on
# Codex's UserPromptSubmit event into <TargetDir>/.codex/hooks.json (referencing
# the hook scripts by absolute path — `command` for POSIX, `commandWindows`
# pwsh for Windows), so a Codex session launched with CODEX_HOME=<TargetDir>/.codex
# picks it up alongside the [otel] config.toml. hooks.json is gitignored.
#
# ConvertTo-Json escapes the Windows backslash paths correctly. Written as UTF-8
# WITHOUT a BOM.
#
# create-if-absent: an existing hooks.json is left untouched (delete to regenerate).
#
# Usage: render-hooks.ps1 -TargetDir <dir>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$HooksDir = Join-Path $ComponentDir 'hooks'
$HookSh  = Join-Path $HooksDir 'capture-user-prompt.sh'
$HookPs1 = Join-Path $HooksDir 'capture-user-prompt.ps1'

foreach ($h in @($HookSh, $HookPs1)) {
    if (-not (Test-Path -LiteralPath $h -PathType Leaf)) {
        Write-Error "FAIL: hook not found: $h"
        exit 1
    }
}

$out = Join-Path $TargetDir '.codex/hooks.json'
if (Test-Path -LiteralPath $out) {
    Write-Host "kept existing $out (delete to regenerate)"
    exit 0
}

$config = [ordered]@{
    hooks = [ordered]@{
        UserPromptSubmit = @(
            [ordered]@{
                hooks = @(
                    [ordered]@{
                        type           = 'command'
                        command        = $HookSh
                        commandWindows = "pwsh -NoProfile -File $HookPs1"
                        timeout        = 10
                        statusMessage  = 'capturing UserPromptSubmit payload (characterization)'
                    }
                )
            }
        )
    }
}

$json = $config | ConvertTo-Json -Depth 10
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null
[System.IO.File]::WriteAllText($out, $json, [System.Text.UTF8Encoding]::new($false))

Write-Host "wrote $out"
