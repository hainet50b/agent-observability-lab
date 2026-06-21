[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$LogsEndpoint,
    [Parameter(Mandatory = $true)][string]$TracesEndpoint,
    [Parameter(Mandatory = $true)][string]$MetricsEndpoint,
    [string]$ApiKey = '',
    [Parameter(Mandatory = $true)][string]$Endpoint
)

$ErrorActionPreference = 'Stop'

$config = Join-Path $TargetDir '.codex/config.toml'

$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path (Join-Path $ComponentDir 'templates') 'otel.template.toml'
. (Join-Path $ComponentDir '../shared/config-place/lib/config-place-core.ps1')

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

# Optional OTLP auth. Empty key -> empty (headers render byte-identically as `{}`);
# present -> ` Authorization = "ApiKey <key>" ` inside the per-exporter table.
$Headers = ''
if ($ApiKey) {
    $Headers = " Authorization = `"ApiKey $ApiKey`" "
}

$block = (Get-Content -Raw -LiteralPath $Template) `
    -replace '@@OTLP_LOGS_ENDPOINT@@', $LogsEndpoint `
    -replace '@@OTLP_TRACES_ENDPOINT@@', $TracesEndpoint `
    -replace '@@OTLP_METRICS_ENDPOINT@@', $MetricsEndpoint `
    -replace '@@OTLP_HEADERS@@', $Headers

Add-CpSection 'otel' 'codex-cli' $Endpoint $block $config '[otel]'
