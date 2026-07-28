[CmdletBinding()]
param(
    [string]$LogsEndpoint,
    [string]$TracesEndpoint,
    [string]$MetricsEndpoint,
    [string]$OtlpApiKey = '',
    [switch]$WithHooks,
    [string]$EsUrl,
    [string]$EsApiKey = '',
    [string]$TimeoutMs = '',
    [string]$UserPromptEnabled = '',
    [string]$UserPromptContent = '',
    [string]$ToolCallEnabled = '',
    [string]$ToolCallContent = '',
    [string]$SealRecipientsSrc = '',
    [string]$SealKeyId = '',
    [ValidateSet('linux', 'macos', 'windows')][string]$Os,
    [string]$RenderDir,
    [string]$BundleVersion = '',
    [string]$BundleVersionFile = ''
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/../../shared/managed-config/lib/managed-config-core.ps1"
. "$PSScriptRoot/lib/managed-config-adapter.ps1"

if ($Os -and -not $RenderDir) { Write-McFatal '-Os requires -RenderDir' }
if ($BundleVersion -and -not $RenderDir) { Write-McFatal '-BundleVersion requires -RenderDir' }
$script:McBundleVersion = $BundleVersion
if ($BundleVersionFile) { $script:McBundleVersionFile = $BundleVersionFile }

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
    $otlpHeaders = if ($OtlpApiKey) { " Authorization = `"ApiKey $OtlpApiKey`" " } else { '' }
    $otelRendered = (Get-Content -Raw -LiteralPath $otelTemplate) `
        -replace '@@OTLP_LOGS_ENDPOINT@@', $LogsEndpoint `
        -replace '@@OTLP_TRACES_ENDPOINT@@', $TracesEndpoint `
        -replace '@@OTLP_METRICS_ENDPOINT@@', $MetricsEndpoint `
        -replace '@@OTLP_HEADERS@@', $otlpHeaders
    $otelSection = ($otelRendered -split "`n" | Select-Object -Skip ([array]::IndexOf(($otelRendered -split "`n"), '[otel]'))) -join "`n"
    $managedRendered = (Get-Content -Raw -LiteralPath $managedTemplate) + "`n" + $otelSection
    $script:McWithTelemetry = $true
}

$hookStageArgs = @($ComponentDir, $EsUrl, $EsApiKey, $TimeoutMs, $UserPromptEnabled, $UserPromptContent, $ToolCallEnabled, $ToolCallContent, $SealRecipientsSrc, $SealKeyId)
if ($WithHooks) {
    if (-not $EsUrl) { Write-McFatal '-WithHooks requires -EsUrl (audit hooks need the ES endpoint)' }
    $script:McWithHooks = $true
}

# Hooks -> requirements.toml (the hook-enforcement layer), with the bundle materialized
# into the host managed_dir. Without -WithHooks there is no enforcement layer to place:
# a telemetry-only managed deploy is managed_config.toml alone (symmetric with Claude's
# env-only managed fragment).
# Codex picks windows_managed_dir on Windows and managed_dir on non-Windows, with no
# fallback (hook_config.rs: managed_dir_for_current_platform), so requirements.toml
# keeps only the key for the target OS.
function Get-OsRequirementsToml($TargetOs) {
    if (-not $WithHooks) { return '' }
    $flavor = Get-McHookFlavor $TargetOs
    $sep = if ($TargetOs -eq 'windows') { '\' } else { '/' }
    $hooksRef = (Get-McManagedRoot $TargetOs) + $sep + 'hooks'
    $certTarget = "$hooksRef/recipient.pem" -replace '\\', '/'
    Add-McHookStage @hookStageArgs $certTarget $flavor | Out-Null
    if ($TargetOs -eq 'windows') {
        $requirementsRendered = (Get-Content -Raw -LiteralPath $requirementsTemplate) `
            -replace '@@WINDOWS_MANAGED_DIR@@', $hooksRef `
            -replace "(?m)^managed_dir = '@@MANAGED_DIR@@'\r?\n", ''
    }
    else {
        $requirementsRendered = (Get-Content -Raw -LiteralPath $requirementsTemplate) `
            -replace '@@MANAGED_DIR@@', $hooksRef `
            -replace "(?m)^windows_managed_dir = '@@WINDOWS_MANAGED_DIR@@'\r?\n", ''
    }
    $hooksRendered = (Get-Content -Raw -LiteralPath $hooksTemplate) `
        -replace '@@AGENT_AUDIT_SH@@', "$hooksRef${sep}agent-audit.sh" `
        -replace '@@AGENT_AUDIT_PS1@@', "$hooksRef${sep}agent-audit.ps1" `
        -replace '@@AGENT_AUDIT_CONF@@', "$hooksRef${sep}agent-audit.conf"
    return $requirementsRendered + "`n" + $hooksRendered
}

$markerEndpoint = "telemetry=$LogsEndpoint;audit=$EsUrl"

$managedSource = [System.IO.Path]::GetTempFileName()
$requirementsSource = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($managedSource, $managedRendered, [System.Text.UTF8Encoding]::new($false))
    if ($RenderDir) {
        $osList = if ($Os) { @($Os) } else { @('linux', 'macos', 'windows') }
        foreach ($targetOs in $osList) {
            [System.IO.File]::WriteAllText($requirementsSource, (Get-OsRequirementsToml $targetOs), [System.Text.UTF8Encoding]::new($false))
            Invoke-McRender -Os $targetOs -RenderDir $RenderDir -Sources @($requirementsSource, $managedSource)
        }
    }
    else {
        $hostOs = Get-McPlatform
        [System.IO.File]::WriteAllText($requirementsSource, (Get-OsRequirementsToml $hostOs), [System.Text.UTF8Encoding]::new($false))
        Invoke-McPlace -Endpoint $markerEndpoint -Sources @($requirementsSource, $managedSource)
    }
}
finally {
    Remove-Item -LiteralPath $managedSource -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $requirementsSource -Force -ErrorAction SilentlyContinue
    if ($script:McHooksStage) { Remove-Item -LiteralPath $script:McHooksStage -Recurse -Force -ErrorAction SilentlyContinue }
}
