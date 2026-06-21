[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$OtlpEndpoint,
    [string]$ApiKey = ''
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath

# Optional OTLP auth. Empty key -> empty headers (rendered byte-identically);
# present -> OTEL_EXPORTER_OTLP_HEADERS = "Authorization=ApiKey <key>".
$OtlpHeaders = ''
if ($ApiKey) {
    $OtlpHeaders = "Authorization=ApiKey $ApiKey"
}

& (Join-Path $ScriptDir 'render-otel.ps1') -TargetDir $TargetDir -LogsEndpoint "$OtlpEndpoint/v1/logs" -TracesEndpoint "$OtlpEndpoint/v1/traces" -MetricsEndpoint "$OtlpEndpoint/v1/metrics" -OtlpHeaders $OtlpHeaders -Endpoint $OtlpEndpoint
