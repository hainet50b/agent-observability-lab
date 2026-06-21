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
$templates = Join-Path $ComponentDir 'templates'
$managedTemplate = Join-Path $templates 'managed_config.template.toml'
$requirementsTemplate = Join-Path $templates 'requirements.template.toml'
$hooksTemplate = Join-Path $templates 'hooks.template.toml'
foreach ($t in @($managedTemplate, $requirementsTemplate, $hooksTemplate)) {
    if (-not (Test-Path -LiteralPath $t -PathType Leaf)) { Write-McFatal "template not found: $t" }
}

# Default: requirements point at the in-repo component hooks (demo). Opt-in
# (staged, off by default): materialize the hook bundle into the host managed_dir
# and point the managed config there. Requires a confirmed host check (stack README).
$hooksRef = Join-Path $ComponentDir 'hooks'
if ($WithHooks) {
    if (-not $EsUrl) { Write-McFatal '--with-hooks requires -EsUrl (audit hooks need the ES endpoint)' }
    $os = Get-McPlatform
    $hooksRef = Join-Path (Get-McManagedRoot $os) 'hooks'
    Add-McHookStage $ComponentDir $EsUrl | Out-Null
    $script:McWithHooks = $true
}

$managedRendered = (Get-Content -Raw -LiteralPath $managedTemplate) `
    -replace '@@OTLP_LOGS_ENDPOINT@@', $LogsEndpoint `
    -replace '@@OTLP_TRACES_ENDPOINT@@', $TracesEndpoint `
    -replace '@@OTLP_METRICS_ENDPOINT@@', $MetricsEndpoint

$requirementsRendered = (Get-Content -Raw -LiteralPath $requirementsTemplate) `
    -replace '@@MANAGED_DIR@@', $hooksRef `
    -replace '@@WINDOWS_MANAGED_DIR@@', $hooksRef

$hooksRendered = (Get-Content -Raw -LiteralPath $hooksTemplate) `
    -replace '@@AGENT_AUDIT_SH@@', (Join-Path $hooksRef 'agent-audit.sh') `
    -replace '@@AGENT_AUDIT_PS1@@', (Join-Path $hooksRef 'agent-audit.ps1') `
    -replace '@@AGENT_AUDIT_CONF@@', (Join-Path $hooksRef 'agent-audit.conf')

$requirementsRendered = $requirementsRendered + "`n" + $hooksRendered

$managedSource = [System.IO.Path]::GetTempFileName()
$requirementsSource = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($managedSource, $managedRendered, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($requirementsSource, $requirementsRendered, [System.Text.UTF8Encoding]::new($false))
    Invoke-McPlace -Endpoint $LogsEndpoint -Sources @($requirementsSource, $managedSource)
}
finally {
    Remove-Item -LiteralPath $managedSource -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $requirementsSource -Force -ErrorAction SilentlyContinue
    if ($script:McHooksStage) { Remove-Item -LiteralPath $script:McHooksStage -Recurse -Force -ErrorAction SilentlyContinue }
}
