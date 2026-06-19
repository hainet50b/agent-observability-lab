#!/usr/bin/env pwsh
# setup-audit.ps1 — configure Codex CLI for the audit concern
# (PowerShell mirror of setup-audit.sh).
#
# Concern-level façade: the stack passes its agent home (-TargetDir) and the
# Elasticsearch URL the hooks write to (-EsUrl); this script owns which render
# steps realize the audit concern AND their order — the hooks block must be
# rendered before the MCP block is appended to config.toml. Renders
# agent-audit.conf, the UserPromptSubmit + PostToolUse hooks, then the
# Elasticsearch MCP config.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$EsUrl
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath

& (Join-Path $ScriptDir 'render-agent-audit.ps1') -EsUrl $EsUrl -TargetDir $TargetDir
& (Join-Path $ScriptDir 'render-hooks.ps1') -TargetDir $TargetDir
& (Join-Path $ScriptDir 'render-mcp.ps1') -TargetDir $TargetDir
