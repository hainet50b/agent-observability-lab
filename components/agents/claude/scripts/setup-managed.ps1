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
$template = Join-Path (Join-Path $ComponentDir 'templates') 'managed-settings.template.json'
if (-not (Test-Path -LiteralPath $template -PathType Leaf)) { Write-McFatal "template not found: $template" }

# Telemetry is optional: render the env block only when the OTLP endpoints are
# present. Without them the managed-settings.json carries no env (just _comment,
# plus hooks if -WithHooks) — an audit-only managed deploy.
$cfg = Get-Content -Raw -LiteralPath $template | ConvertFrom-Json
if ($WithTelemetry) {
    $otelTemplate = Join-Path (Join-Path $ComponentDir 'templates') 'otel.template.json'
    if (-not (Test-Path -LiteralPath $otelTemplate -PathType Leaf)) { Write-McFatal "template not found: $otelTemplate" }
    $otlpHeaders = if ($OtlpApiKey) { "Authorization=ApiKey $OtlpApiKey" } else { '' }
    $otelEnv = ((Get-Content -Raw -LiteralPath $otelTemplate) `
            -replace '@@OTLP_LOGS_ENDPOINT@@', $LogsEndpoint `
            -replace '@@OTLP_TRACES_ENDPOINT@@', $TracesEndpoint `
            -replace '@@OTLP_METRICS_ENDPOINT@@', $MetricsEndpoint `
            -replace '@@OTLP_HEADERS@@', $otlpHeaders | ConvertFrom-Json).env
    if ($otelEnv.OTEL_EXPORTER_OTLP_HEADERS -eq '') {
        $otelEnv.PSObject.Properties.Remove('OTEL_EXPORTER_OTLP_HEADERS')
    }
    $cfg | Add-Member -NotePropertyName 'env' -NotePropertyValue $otelEnv -Force
}
$rendered = $cfg | ConvertTo-Json -Depth 10

$markerEndpoint = "telemetry=$LogsEndpoint;audit=$EsUrl"

$hookTemplate = Join-Path (Join-Path $ComponentDir 'templates') 'hook.template.json'
$hookStageArgs = @($ComponentDir, $EsUrl, $EsApiKey, $TimeoutMs, $UserPromptEnabled, $UserPromptContent, $ToolCallEnabled, $ToolCallContent, $SealRecipientsSrc, $SealKeyId)
if ($WithHooks) {
    if (-not $EsUrl) { Write-McFatal '--with-hooks requires -EsUrl (audit hooks need the ES endpoint)' }
    if (-not (Test-Path -LiteralPath $hookTemplate -PathType Leaf)) { Write-McFatal "hook template not found: $hookTemplate" }
    $script:McWithHooks = $true
}

# Opt-in (staged, off by default): also enforce the audit hooks org-wide by
# materializing the hook bundle beside managed-settings.json and adding a hooks
# block that points at it. Requires a confirmed host check (see the stack README).
# The hook block, the hook bundle flavor (sh vs ps1) and the paths baked into
# agent-audit.conf are all per-OS, so the managed-settings.json is finalized once
# per target OS. Output is normalized to LF with a trailing newline so a bundle
# rendered here is byte-identical to one rendered by setup-managed.sh.
function Get-OsRendered($TargetOs) {
    $doc = $rendered | ConvertFrom-Json
    if ($WithHooks) {
        $root = Get-McManagedRoot $TargetOs
        $flavor = Get-McHookFlavor $TargetOs
        $certTarget = "$root/hooks/recipient.pem" -replace '\\', '/'
        Add-McHookStage @hookStageArgs $certTarget $flavor | Out-Null
        $tpl = Get-Content -Raw -LiteralPath $hookTemplate | ConvertFrom-Json
        foreach ($h in @(
                @{ entry = $tpl.hooks.UserPromptSubmit[0].hooks[0]; stream = 'user_prompt' },
                @{ entry = $tpl.hooks.PostToolUse[0].hooks[0]; stream = 'tool_call' }
            )) {
            if ($flavor -eq 'ps1') {
                $h.entry.command = 'powershell'
                $h.entry | Add-Member -NotePropertyName 'args' -NotePropertyValue @(
                    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                    '-File', "$root\hooks\agent-audit.ps1", '-Stream', $h.stream, '-Config', "$root\hooks\agent-audit.conf"
                ) -Force
            }
            else {
                $h.entry.command = "'$root/hooks/agent-audit.sh' --stream $($h.stream) --config '$root/hooks/agent-audit.conf'"
            }
        }
        $doc | Add-Member -NotePropertyName 'hooks' -NotePropertyValue $tpl.hooks -Force
    }
    return (($doc | ConvertTo-Json -Depth 10) -replace "`r`n", "`n") + "`n"
}

$source = [System.IO.Path]::GetTempFileName()
try {
    if ($RenderDir) {
        $osList = if ($Os) { @($Os) } else { @('linux', 'macos', 'windows') }
        foreach ($targetOs in $osList) {
            [System.IO.File]::WriteAllText($source, (Get-OsRendered $targetOs), [System.Text.UTF8Encoding]::new($false))
            Invoke-McRender -Os $targetOs -RenderDir $RenderDir -Sources @($source)
        }
    }
    else {
        [System.IO.File]::WriteAllText($source, (Get-OsRendered (Get-McPlatform)), [System.Text.UTF8Encoding]::new($false))
        Invoke-McPlace -Endpoint $markerEndpoint -Sources @($source)
    }
}
finally {
    Remove-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
    if ($script:McHooksStage) { Remove-Item -LiteralPath $script:McHooksStage -Recurse -Force -ErrorAction SilentlyContinue }
}
