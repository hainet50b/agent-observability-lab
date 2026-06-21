[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LogsEndpoint,
    [Parameter(Mandatory = $true)][string]$TracesEndpoint,
    [Parameter(Mandatory = $true)][string]$MetricsEndpoint
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/../../shared/managed-config/lib/managed-config-core.ps1"
. "$PSScriptRoot/lib/managed-config-adapter.ps1"

$ComponentDir = Split-Path -Parent $PSScriptRoot
$template = Join-Path (Join-Path $ComponentDir 'templates') 'managed-settings.template.json'
if (-not (Test-Path -LiteralPath $template -PathType Leaf)) { McFail "template not found: $template" }

$rendered = (Get-Content -Raw -LiteralPath $template) `
    -replace '@@OTLP_LOGS_ENDPOINT@@', $LogsEndpoint `
    -replace '@@OTLP_TRACES_ENDPOINT@@', $TracesEndpoint `
    -replace '@@OTLP_METRICS_ENDPOINT@@', $MetricsEndpoint

$source = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($source, $rendered, [System.Text.UTF8Encoding]::new($false))
    Invoke-McPlace -Endpoint $LogsEndpoint -Sources @($source)
}
finally {
    Remove-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
}





