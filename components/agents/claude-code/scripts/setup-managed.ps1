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
$template = Join-Path (Join-Path $ComponentDir 'templates') 'managed-settings.template.json'
if (-not (Test-Path -LiteralPath $template -PathType Leaf)) { Write-McFatal "template not found: $template" }

# Telemetry is optional: render the env block only when the OTLP endpoints are
# present. Without them the managed-settings.json carries no env (just _comment,
# plus hooks if -WithHooks) — an audit-only managed deploy.
$cfg = Get-Content -Raw -LiteralPath $template | ConvertFrom-Json
if ($WithTelemetry) {
    $otelTemplate = Join-Path (Join-Path $ComponentDir 'templates') 'otel.template.json'
    if (-not (Test-Path -LiteralPath $otelTemplate -PathType Leaf)) { Write-McFatal "template not found: $otelTemplate" }
    $otelEnv = ((Get-Content -Raw -LiteralPath $otelTemplate) `
            -replace '@@OTLP_LOGS_ENDPOINT@@', $LogsEndpoint `
            -replace '@@OTLP_TRACES_ENDPOINT@@', $TracesEndpoint `
            -replace '@@OTLP_METRICS_ENDPOINT@@', $MetricsEndpoint `
            -replace '@@OTLP_HEADERS@@', '' | ConvertFrom-Json).env
    if ($otelEnv.OTEL_EXPORTER_OTLP_HEADERS -eq '') {
        $otelEnv.PSObject.Properties.Remove('OTEL_EXPORTER_OTLP_HEADERS')
    }
    $cfg | Add-Member -NotePropertyName 'env' -NotePropertyValue $otelEnv -Force
}
$rendered = $cfg | ConvertTo-Json -Depth 10

# Audit-only deploy has no logs endpoint; key the marker/ownership on the audit ES
# url so Invoke-McPlace and the provenance marker are meaningful.
$markerEndpoint = if ($WithTelemetry) { $LogsEndpoint } else { $EsUrl }

# Opt-in (staged, off by default): also enforce the audit hooks org-wide by
# materializing the hook bundle beside managed-settings.json and adding an
# exec-form hooks block. Requires a confirmed host check (see the stack README).
if ($WithHooks) {
    if (-not $EsUrl) { Write-McFatal '--with-hooks requires -EsUrl (audit hooks need the ES endpoint)' }
    $os = Get-McPlatform
    $hooksTarget = Join-Path (Get-McManagedRoot $os) 'hooks'
    Add-McHookStage $ComponentDir $EsUrl $EsApiKey $TimeoutMs $UserPromptEnabled $UserPromptContent $ToolCallEnabled $ToolCallContent | Out-Null
    $entryTarget = Join-Path $hooksTarget 'agent-audit.ps1'
    $confTarget = Join-Path $hooksTarget 'agent-audit.conf'
    $hookTemplate = Join-Path (Join-Path $ComponentDir 'templates') 'hook.template.json'
    if (-not (Test-Path -LiteralPath $hookTemplate -PathType Leaf)) { Write-McFatal "hook template not found: $hookTemplate" }
    $tpl = Get-Content -Raw -LiteralPath $hookTemplate | ConvertFrom-Json
    foreach ($h in @(
            @{ entry = $tpl.hooks.UserPromptSubmit[0].hooks[0]; stream = 'user_prompt' },
            @{ entry = $tpl.hooks.PostToolUse[0].hooks[0]; stream = 'tool_call' }
        )) {
        $h.entry.command = 'powershell'
        $h.entry | Add-Member -NotePropertyName 'args' -NotePropertyValue @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $entryTarget, '-Stream', $h.stream, '-Config', $confTarget
        ) -Force
    }
    $cfg = $rendered | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName 'hooks' -NotePropertyValue $tpl.hooks -Force
    $rendered = $cfg | ConvertTo-Json -Depth 10
    $script:McWithHooks = $true
}

$source = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($source, $rendered, [System.Text.UTF8Encoding]::new($false))
    Invoke-McPlace -Endpoint $markerEndpoint -Sources @($source)
}
finally {
    Remove-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
    if ($script:McHooksStage) { Remove-Item -LiteralPath $script:McHooksStage -Recurse -Force -ErrorAction SilentlyContinue }
}
