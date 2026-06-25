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

# Merge our .env into the existing settings.local.json, preserving any other
# top-level keys (e.g. .hooks placed by the audit concern sharing this home).
$merged = if (Test-Path -LiteralPath $out -PathType Leaf) {
    Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
}
else {
    [pscustomobject]@{}
}
$merged | Add-Member -NotePropertyName 'env' -NotePropertyValue $envBlock -Force

$tmp = [System.IO.Path]::GetTempFileName()
try {
    ($merged | ConvertTo-Json -Depth 10) |
        Set-Content -LiteralPath $tmp -Encoding utf8
    Set-CpFile 'otel' 'claude-code' $Endpoint $tmp $out
    Set-CpSelfIgnore 'claude-code' $Endpoint (Join-Path $TargetDir '.claude')
}
finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
