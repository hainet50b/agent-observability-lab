[CmdletBinding()]
param(
    [switch]$WithHooks
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/../../shared/managed-config/lib/managed-config-core.ps1"
. "$PSScriptRoot/lib/managed-config-adapter.ps1"

if ($WithHooks) { $script:McWithHooks = $true }
# Teardown enumerates every candidate target for removal; an absent one is a
# harmless no-op. Force telemetry targets in so a telemetry deploy's
# managed_config.toml is removed even though teardown carries no endpoints.
$script:McWithTelemetry = $true
Invoke-McTeardown
