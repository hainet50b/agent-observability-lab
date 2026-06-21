[CmdletBinding()]
param(
    [string]$Scope = 'local',
    [string]$Target,
    [string]$Config
)

$ErrorActionPreference = 'Stop'

$backendArgs = @{}
if ($Config) {
    $backendArgs['Config'] = $Config
}
& (Join-Path $PSScriptRoot 'setup-backend.ps1') @backendArgs

Write-Host ''

$configArgs = @{ Scope = $Scope }
if ($Target) {
    $configArgs['Target'] = $Target
}
if ($Config) {
    $configArgs['Config'] = $Config
}
& (Join-Path $PSScriptRoot 'setup-config.ps1') @configArgs
