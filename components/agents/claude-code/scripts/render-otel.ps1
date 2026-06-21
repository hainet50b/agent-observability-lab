[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$LogsEndpoint,
    [Parameter(Mandatory = $true)][string]$TracesEndpoint,
    [Parameter(Mandatory = $true)][string]$MetricsEndpoint,
    [string]$OtlpHeaders = '',
    [Parameter(Mandatory = $true)][string]$Endpoint
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path (Join-Path $ComponentDir 'templates') 'otel.template.json'
. (Join-Path $ComponentDir '../shared/config-place/lib/config-place-core.ps1')

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

$out = Join-Path $TargetDir '.claude/settings.local.json'

$rendered = (Get-Content -Raw -LiteralPath $Template) `
    -replace '@@OTLP_LOGS_ENDPOINT@@', $LogsEndpoint `
    -replace '@@OTLP_TRACES_ENDPOINT@@', $TracesEndpoint `
    -replace '@@OTLP_METRICS_ENDPOINT@@', $MetricsEndpoint `
    -replace '@@OTLP_HEADERS@@', $OtlpHeaders
$envBlock = ($rendered | ConvertFrom-Json).env

$tmp = New-TemporaryFile
try {
    ([pscustomobject]@{ env = $envBlock } | ConvertTo-Json -Depth 8) |
        Set-Content -LiteralPath $tmp -Encoding utf8
    Set-CpFile 'otel' 'claude-code' $Endpoint $tmp $out
}
finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
