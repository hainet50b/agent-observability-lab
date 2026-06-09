#!/usr/bin/env pwsh
# render-config.ps1 — render the Codex CLI agent's .codex/config.toml
# (PowerShell mirror of render-config.sh).
#
# The telemetry config content (the [otel] block) lives once in the agent-owned
# template ../config.template.toml. This fills the one non-agent value — the
# stack's OTLP endpoint — into <TargetDir>/.codex/config.toml, so a Codex session
# launched with CODEX_HOME=<TargetDir>/.codex reads it as user-level config and
# emits into the stack without touching the user's ~/.codex. (A repo-local
# .codex/config.toml does NOT work for [otel] — Codex ignores otel keys in
# project-local config; CODEX_HOME is the supported per-project mechanism.) The
# rendered file is gitignored (.codex/ in the repo root).
#
# Written as UTF-8 WITHOUT a BOM: a leading BOM is not stripped by TOML parsers
# (Codex uses the Rust `toml` crate) and would corrupt the first key.
#
# create-if-absent: an existing config.toml is left untouched.
#
# Usage: render-config.ps1 -OtlpEndpoint <url> -TargetDir <dir>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OtlpEndpoint,
    [Parameter(Mandatory = $true)][string]$TargetDir
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path $ComponentDir 'config.template.toml'

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

$out = Join-Path $TargetDir '.codex/config.toml'
if (Test-Path -LiteralPath $out) {
    Write-Host "kept existing $out (delete to regenerate)"
    exit 0
}

$content = (Get-Content -Raw -LiteralPath $Template) -replace '@@OTLP_ENDPOINT@@', $OtlpEndpoint
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null
[System.IO.File]::WriteAllText($out, $content, [System.Text.UTF8Encoding]::new($false))

Write-Host "wrote $out"
