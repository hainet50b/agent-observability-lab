# setup-telemetry.ps1 — configure Claude Code for the telemetry concern
# (PowerShell mirror of setup-telemetry.sh).
#
# Concern-level façade: the stack passes its agent home (-TargetDir) and the OTLP
# base (-OtlpEndpoint); this script owns which render steps realize the telemetry
# concern. Renders the OTel env (the three OTLP signal endpoints derived from the
# base) and the Elasticsearch MCP config into the agent home.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$OtlpEndpoint
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath

& (Join-Path $ScriptDir 'render-otel.ps1') -TargetDir $TargetDir -LogsEndpoint "$OtlpEndpoint/v1/logs" -TracesEndpoint "$OtlpEndpoint/v1/traces" -MetricsEndpoint "$OtlpEndpoint/v1/metrics"
& (Join-Path $ScriptDir 'render-mcp.ps1') -TargetDir $TargetDir
