[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$LogsEndpoint,
    [Parameter(Mandatory = $true)][string]$TracesEndpoint,
    [Parameter(Mandatory = $true)][string]$MetricsEndpoint
)

$ErrorActionPreference = 'Stop'

$config = Join-Path $TargetDir '.codex/config.toml'

if (Test-Path -LiteralPath $config) {
    Write-Host "Skipped: $config already exists (delete to regenerate)"
    exit 0
}

$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path (Join-Path $ComponentDir 'templates') 'otel.template.toml'

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

$content = (Get-Content -Raw -LiteralPath $Template) `
    -replace '@@OTLP_LOGS_ENDPOINT@@', $LogsEndpoint `
    -replace '@@OTLP_TRACES_ENDPOINT@@', $TracesEndpoint `
    -replace '@@OTLP_METRICS_ENDPOINT@@', $MetricsEndpoint
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $config) | Out-Null
[System.IO.File]::WriteAllText($config, $content, [System.Text.UTF8Encoding]::new($false))

