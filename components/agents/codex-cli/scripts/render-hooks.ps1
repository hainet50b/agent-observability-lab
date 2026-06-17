#!/usr/bin/env pwsh
# render-hooks.ps1 — append the Codex CLI agent's [hooks] tables to
# <TargetDir>/.codex/config.toml (PowerShell mirror of render-hooks.sh).
#
# Registers two hooks as inline [[hooks.<Event>]] tables in config.toml
# (referencing the hook scripts by absolute path — `command` for POSIX,
# `commandWindows` pwsh for Windows), so a Codex session launched with
# CODEX_HOME=<TargetDir>/.codex picks them up alongside the [otel] / [mcp_servers]
# tables the other render-* scripts append to the same config.toml (one
# representation per layer: inline [hooks], never a sidecar hooks.json):
#   * UserPromptSubmit -> hooks/capture-user-prompt.{sh,ps1} — production Agent
#     Audit hook; delivers each submitted prompt to the local Agent Audit data
#     stream using the delivery config in .codex/agent-audit.toml.
#   * PostToolUse -> hooks/capture-tool-call.{sh,ps1} — production Agent Audit
#     tool-call hook; delivers each completed tool call to the local Agent Audit
#     data stream logs-agent_audit.tool_call-default using .codex/agent-audit.toml.
# config.toml is gitignored. Paths are TOML literal strings, so the Windows
# backslash paths need no escaping. Written as UTF-8 WITHOUT a BOM.
#
# append-if-absent: skip when config.toml already contains [[hooks.UserPromptSubmit]]
# (delete the [hooks] tables to regenerate); otherwise append (blank-line separated)
# or create.
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
$HookSh = Join-Path $HooksDir 'capture-user-prompt.sh'
$HookPs1 = Join-Path $HooksDir 'capture-user-prompt.ps1'
$ToolSh = Join-Path $HooksDir 'capture-tool-call.sh'
$ToolPs1 = Join-Path $HooksDir 'capture-tool-call.ps1'
$Template = Join-Path $ComponentDir 'hooks.template.toml'

foreach ($h in @($HookSh, $HookPs1, $ToolSh, $ToolPs1)) {
    if (-not (Test-Path -LiteralPath $h -PathType Leaf)) {
        Write-Error "FAIL: hook not found: $h"
        exit 1
    }
}
if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

$config = Join-Path $TargetDir '.codex/config.toml'

if ((Test-Path -LiteralPath $config) -and (Select-String -LiteralPath $config -SimpleMatch '[[hooks.UserPromptSubmit]]' -Quiet)) {
    Write-Host "Skipped: $config already has [[hooks.UserPromptSubmit]]"
    exit 0
}

$block = ((Get-Content -Raw -LiteralPath $Template) -replace "`r`n", "`n").
Replace('@@USER_PROMPT_SH@@', $HookSh).
Replace('@@USER_PROMPT_PS1@@', $HookPs1).
Replace('@@TOOL_CALL_SH@@', $ToolSh).
Replace('@@TOOL_CALL_PS1@@', $ToolPs1)

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $config) | Out-Null
if (Test-Path -LiteralPath $config) {
    $existing = ((Get-Content -Raw -LiteralPath $config) -replace "`r`n", "`n").TrimEnd("`n")
    $combined = $existing + "`n`n" + $block
} else {
    $combined = $block
}
[System.IO.File]::WriteAllText($config, $combined, [System.Text.UTF8Encoding]::new($false))

Write-Host "wrote [hooks] tables to $config"
