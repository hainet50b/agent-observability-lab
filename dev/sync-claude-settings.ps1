#!/usr/bin/env pwsh
# sync-claude-settings.ps1 — DEV-ONLY helper for lab maintainers (mirror of .sh).
#
# Copies a stack's generated stacks/<stack>/.claude/settings.local.json (telemetry
# env + audit hook) up to the repo-root .claude/, so a `claude` launched at the
# repo root (a maintainer's habit) uses the same config. Project settings load
# from the launch dir, not parents. The .claude/ dirs are gitignored; only this
# helper is committed.
#
# Usage:  dev/sync-claude-settings.ps1 <stack>
#   e.g.  dev/sync-claude-settings.ps1 claude-code-otelcol-elastic

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Stack
)

$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$src = Join-Path $Repo "stacks/$Stack/.claude/settings.local.json"
$dst = Join-Path $Repo '.claude/settings.local.json'

if (-not (Test-Path -LiteralPath $src)) {
    Write-Error "not found: $src`nrun 'cd stacks/$Stack; scripts/setup.ps1' first"
    exit 1
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
Copy-Item -LiteralPath $src -Destination $dst -Force
Write-Host "copied $src -> $dst"
Write-Host "a 'claude' launched at the repo root now uses the $Stack telemetry + audit config."
