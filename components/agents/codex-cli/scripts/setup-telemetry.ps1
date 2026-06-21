[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$OtlpEndpoint,
    [string]$ApiKey = ''
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath

& (Join-Path $ScriptDir 'render-otel.ps1') -TargetDir $TargetDir -LogsEndpoint "$OtlpEndpoint/v1/logs" -TracesEndpoint "$OtlpEndpoint/v1/traces" -MetricsEndpoint "$OtlpEndpoint/v1/metrics" -ApiKey $ApiKey -Endpoint $OtlpEndpoint
