[CmdletBinding()]
param(
    [string]$LogsEndpoint,
    [string]$TracesEndpoint,
    [string]$MetricsEndpoint,
    [switch]$WithHooks,
    [string]$EsUrl,
    [string]$EsApiKey = '',
    [string]$TimeoutMs = '',
    [string]$UserPromptEnabled = '',
    [string]$UserPromptContent = '',
    [string]$ToolCallEnabled = '',
    [string]$ToolCallContent = ''
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/../../shared/managed-config/lib/managed-config-core.ps1"
. "$PSScriptRoot/lib/managed-config-adapter.ps1"

$WithTelemetry = $false
if ($LogsEndpoint -or $TracesEndpoint -or $MetricsEndpoint) {
    if (-not $LogsEndpoint) { Write-McFatal '-LogsEndpoint is required (full OTLP URL, e.g. http://localhost:8200/v1/logs)' }
    if (-not $TracesEndpoint) { Write-McFatal '-TracesEndpoint is required (full OTLP URL, e.g. http://localhost:8200/v1/traces)' }
    if (-not $MetricsEndpoint) { Write-McFatal '-MetricsEndpoint is required (full OTLP URL, e.g. http://localhost:8200/v1/metrics)' }
    $WithTelemetry = $true
}
if (-not $WithTelemetry -and -not $WithHooks) {
    Write-McFatal 'nothing to place (need OTLP endpoints and/or -WithHooks)'
}

$ComponentDir = Split-Path -Parent $PSScriptRoot
$templates = Join-Path $ComponentDir 'templates'
$requirementsTemplate = Join-Path $templates 'requirements.template.toml'
$hooksTemplate = Join-Path $templates 'hooks.template.toml'
foreach ($t in @($requirementsTemplate, $hooksTemplate)) {
    if (-not (Test-Path -LiteralPath $t -PathType Leaf)) { Write-McFatal "template not found: $t" }
}

# Telemetry -> managed_config.toml ([otel] defaults), only when the OTLP endpoints are present.
$managedRendered = ''
if ($WithTelemetry) {
    $managedTemplate = Join-Path $templates 'managed_config.template.toml'
    $otelTemplate = Join-Path $templates 'otel.template.toml'
    foreach ($t in @($managedTemplate, $otelTemplate)) {
        if (-not (Test-Path -LiteralPath $t -PathType Leaf)) { Write-McFatal "template not found: $t" }
    }
    $otelRendered = (Get-Content -Raw -LiteralPath $otelTemplate) `
        -replace '@@OTLP_LOGS_ENDPOINT@@', $LogsEndpoint `
        -replace '@@OTLP_TRACES_ENDPOINT@@', $TracesEndpoint `
        -replace '@@OTLP_METRICS_ENDPOINT@@', $MetricsEndpoint `
        -replace '@@OTLP_HEADERS@@', ''
    $otelSection = ($otelRendered -split "`n" | Select-Object -Skip ([array]::IndexOf(($otelRendered -split "`n"), '[otel]'))) -join "`n"
    $managedRendered = (Get-Content -Raw -LiteralPath $managedTemplate) + "`n" + $otelSection
    $script:McWithTelemetry = $true
}

# Hooks -> requirements.toml (the hook-enforcement layer), with the bundle materialized
# into the host managed_dir. Without -WithHooks there is no enforcement layer to place:
# a telemetry-only managed deploy is managed_config.toml alone (symmetric with Claude's
# env-only managed-settings.json).
$requirementsRendered = ''
if ($WithHooks) {
    if (-not $EsUrl) { Write-McFatal '-WithHooks requires -EsUrl (audit hooks need the ES endpoint)' }
    $os = Get-McPlatform
    $hooksRef = Join-Path (Get-McManagedRoot $os) 'hooks'
    Add-McHookStage $ComponentDir $EsUrl $EsApiKey $TimeoutMs $UserPromptEnabled $UserPromptContent $ToolCallEnabled $ToolCallContent | Out-Null
    $script:McWithHooks = $true
    $requirementsRendered = (Get-Content -Raw -LiteralPath $requirementsTemplate) `
        -replace '@@MANAGED_DIR@@', $hooksRef `
        -replace '@@WINDOWS_MANAGED_DIR@@', $hooksRef
    $hooksRendered = (Get-Content -Raw -LiteralPath $hooksTemplate) `
        -replace '@@AGENT_AUDIT_SH@@', (Join-Path $hooksRef 'agent-audit.sh') `
        -replace '@@AGENT_AUDIT_PS1@@', (Join-Path $hooksRef 'agent-audit.ps1') `
        -replace '@@AGENT_AUDIT_CONF@@', (Join-Path $hooksRef 'agent-audit.conf')
    $requirementsRendered = $requirementsRendered + "`n" + $hooksRendered
}

$markerEndpoint = if ($WithTelemetry) { $LogsEndpoint } else { $EsUrl }

$managedSource = [System.IO.Path]::GetTempFileName()
$requirementsSource = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($managedSource, $managedRendered, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($requirementsSource, $requirementsRendered, [System.Text.UTF8Encoding]::new($false))
    Invoke-McPlace -Endpoint $markerEndpoint -Sources @($requirementsSource, $managedSource)
}
finally {
    Remove-Item -LiteralPath $managedSource -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $requirementsSource -Force -ErrorAction SilentlyContinue
    if ($script:McHooksStage) { Remove-Item -LiteralPath $script:McHooksStage -Recurse -Force -ErrorAction SilentlyContinue }
}
