#!/usr/bin/env pwsh
# setup-telemetry.ps1 — configure Codex CLI for the telemetry concern
# (PowerShell mirror of setup-telemetry.sh).
#
# Concern-level façade: the stack passes its agent home (-TargetDir) and the OTLP
# endpoint (-OtlpEndpoint); this script owns which render steps realize the
# telemetry concern. Renders the [otel] config.toml block and the Elasticsearch
# MCP config into the agent home.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$OtlpEndpoint
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath

& (Join-Path $ScriptDir 'render-otel.ps1') -OtlpEndpoint $OtlpEndpoint -TargetDir $TargetDir
& (Join-Path $ScriptDir 'render-mcp.ps1') -TargetDir $TargetDir
