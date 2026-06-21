[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Stack,
    [Parameter(Mandatory = $true)][string]$Endpoint
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/../../shared/managed-config/lib/managed-config-core.ps1"
. "$PSScriptRoot/lib/managed-config-adapter.ps1"

$ComponentDir = Split-Path -Parent $PSScriptRoot
$templates = Join-Path $ComponentDir 'templates'
$managedTemplate = Join-Path $templates 'managed_config.template.toml'
$requirementsTemplate = Join-Path $templates 'requirements.template.toml'
foreach ($t in @($managedTemplate, $requirementsTemplate)) {
    if (-not (Test-Path -LiteralPath $t -PathType Leaf)) { McFail "template not found: $t" }
}

$hooksDir = Join-Path $ComponentDir 'hooks'

$managedRendered = (Get-Content -Raw -LiteralPath $managedTemplate) `
    -replace '@@OTLP_LOGS_ENDPOINT@@', "$Endpoint/v1/logs" `
    -replace '@@OTLP_TRACES_ENDPOINT@@', "$Endpoint/v1/traces" `
    -replace '@@OTLP_METRICS_ENDPOINT@@', "$Endpoint/v1/metrics"

$requirementsRendered = (Get-Content -Raw -LiteralPath $requirementsTemplate) `
    -replace '@@MANAGED_DIR@@', $hooksDir `
    -replace '@@WINDOWS_MANAGED_DIR@@', $hooksDir `
    -replace '@@AGENT_AUDIT_SH@@', (Join-Path $hooksDir 'agent-audit.sh') `
    -replace '@@AGENT_AUDIT_PS1@@', (Join-Path $hooksDir 'agent-audit.ps1') `
    -replace '@@AGENT_AUDIT_CONF@@', (Join-Path $hooksDir 'agent-audit.conf')

$script:McSourceManagedConfig = [System.IO.Path]::GetTempFileName()
$script:McSourceRequirements = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($script:McSourceManagedConfig, $managedRendered, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($script:McSourceRequirements, $requirementsRendered, [System.Text.UTF8Encoding]::new($false))
    Invoke-McPlace -Stack $Stack -Endpoint $Endpoint
}
finally {
    Remove-Item -LiteralPath $script:McSourceManagedConfig -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:McSourceRequirements -Force -ErrorAction SilentlyContinue
}

