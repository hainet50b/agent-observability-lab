[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$OtlpEndpoint,
    [string]$ApiKey = '',
    [string]$MarkerEndpoint = ''
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath

# Ownership marker endpoint. Defaults to the OTLP data-plane endpoint (the lab's
# single-concern behaviour); a caller sharing one home across concerns passes a
# unified value so every bundle file carries the same marker.
$Marker = if ($MarkerEndpoint) { $MarkerEndpoint } else { $OtlpEndpoint }

& (Join-Path $ScriptDir 'render-otel.ps1') -TargetDir $TargetDir -LogsEndpoint "$OtlpEndpoint/v1/logs" -TracesEndpoint "$OtlpEndpoint/v1/traces" -MetricsEndpoint "$OtlpEndpoint/v1/metrics" -ApiKey $ApiKey -Endpoint $Marker
