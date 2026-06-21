[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Stack,
    [Parameter(Mandatory = $true)][string]$Endpoint
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/../../shared/managed-config/lib/managed-config-core.ps1"
. "$PSScriptRoot/lib/managed-config-adapter.ps1"

$ComponentDir = Split-Path -Parent $PSScriptRoot
$template = Join-Path (Join-Path $ComponentDir 'templates') 'managed-settings.template.json'
if (-not (Test-Path -LiteralPath $template -PathType Leaf)) { McFail "template not found: $template" }

$rendered = (Get-Content -Raw -LiteralPath $template) `
    -replace '@@OTLP_LOGS_ENDPOINT@@', "$Endpoint/v1/logs" `
    -replace '@@OTLP_TRACES_ENDPOINT@@', "$Endpoint/v1/traces" `
    -replace '@@OTLP_METRICS_ENDPOINT@@', "$Endpoint/v1/metrics" `
    -replace '@@OTLP_HEADERS@@', ''

$script:McSource = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($script:McSource, $rendered, [System.Text.UTF8Encoding]::new($false))
    Invoke-McPlace -Stack $Stack -Endpoint $Endpoint
}
finally {
    Remove-Item -LiteralPath $script:McSource -Force -ErrorAction SilentlyContinue
}

