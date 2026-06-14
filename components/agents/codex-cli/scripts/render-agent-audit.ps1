#!/usr/bin/env pwsh
# render-agent-audit.ps1 — render the Codex CLI agent's .codex/agent-audit.toml
# (PowerShell mirror of render-agent-audit.sh).
#
# Fills the single @@ES_URL@@ placeholder in the agent-owned template
# ../agent-audit.template.toml with the stack's Elasticsearch base URL and writes
# <TargetDir>/.codex/agent-audit.toml — the Agent Audit hook's Elasticsearch
# delivery config, beside config.toml / hooks.json under CODEX_HOME. The
# UserPromptSubmit hook reads this file to deliver captured prompts to the local
# Agent Audit data stream (see ../../../SPEC/agent-audit.md). This script only
# GENERATES the delivery config. The rendered file is gitignored (.codex/).
#
# Written as UTF-8 WITHOUT a BOM: a leading BOM is not stripped by TOML parsers
# (Codex uses the Rust `toml` crate) and would corrupt the first key.
#
# create-if-absent: an existing agent-audit.toml is left untouched (delete to regenerate).
#
# Usage: render-agent-audit.ps1 -EsUrl <url> -TargetDir <dir>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EsUrl,
    [Parameter(Mandatory = $true)][string]$TargetDir
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path $ComponentDir 'agent-audit.template.toml'

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

$out = Join-Path $TargetDir '.codex/agent-audit.toml'
if (Test-Path -LiteralPath $out) {
    Write-Host "kept existing $out (delete to regenerate)"
    exit 0
}

$content = (Get-Content -Raw -LiteralPath $Template) -replace '@@ES_URL@@', $EsUrl
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null
[System.IO.File]::WriteAllText($out, $content, [System.Text.UTF8Encoding]::new($false))

Write-Host "wrote $out"
