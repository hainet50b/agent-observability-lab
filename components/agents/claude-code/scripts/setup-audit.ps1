# setup-audit.ps1 — configure Claude Code for the audit concern
# (PowerShell mirror of setup-audit.sh).
#
# Concern-level façade: the stack passes its agent home (-TargetDir) and the
# Elasticsearch URL the hook writes to (-EsUrl); this script owns which render
# steps realize the audit concern. Renders the UserPromptSubmit audit hook, the
# agent-audit.conf delivery config, and the Elasticsearch MCP config.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$EsUrl
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath

& (Join-Path $ScriptDir 'render-hook.ps1') -TargetDir $TargetDir
& (Join-Path $ScriptDir 'render-agent-audit.ps1') -EsUrl $EsUrl -TargetDir $TargetDir
& (Join-Path $ScriptDir 'render-mcp.ps1') -TargetDir $TargetDir
