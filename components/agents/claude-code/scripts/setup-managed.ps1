[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LogsEndpoint,
    [Parameter(Mandatory = $true)][string]$TracesEndpoint,
    [Parameter(Mandatory = $true)][string]$MetricsEndpoint,
    [switch]$WithHooks,
    [string]$EsUrl
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/../../shared/managed-config/lib/managed-config-core.ps1"
. "$PSScriptRoot/lib/managed-config-adapter.ps1"

$ComponentDir = Split-Path -Parent $PSScriptRoot
$template = Join-Path (Join-Path $ComponentDir 'templates') 'managed-settings.template.json'
if (-not (Test-Path -LiteralPath $template -PathType Leaf)) { Write-McFatal "template not found: $template" }

$rendered = (Get-Content -Raw -LiteralPath $template) `
    -replace '@@OTLP_LOGS_ENDPOINT@@', $LogsEndpoint `
    -replace '@@OTLP_TRACES_ENDPOINT@@', $TracesEndpoint `
    -replace '@@OTLP_METRICS_ENDPOINT@@', $MetricsEndpoint

# Opt-in (staged, off by default): also enforce the audit hooks org-wide by
# materializing the hook bundle beside managed-settings.json and adding an
# exec-form hooks block. Requires a confirmed host check (see the stack README).
if ($WithHooks) {
    if (-not $EsUrl) { Write-McFatal '--with-hooks requires -EsUrl (audit hooks need the ES endpoint)' }
    $os = Get-McPlatform
    $hooksTarget = Join-Path (Get-McManagedRoot $os) 'hooks'
    Add-McHookStage $ComponentDir $EsUrl | Out-Null
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
    Invoke-McPlace -Endpoint $LogsEndpoint -Sources @($source)
}
finally {
    Remove-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
    if ($script:McHooksStage) { Remove-Item -LiteralPath $script:McHooksStage -Recurse -Force -ErrorAction SilentlyContinue }
}







