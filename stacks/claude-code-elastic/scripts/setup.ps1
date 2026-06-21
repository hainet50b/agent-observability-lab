[CmdletBinding()]
param(
    [string]$Scope = 'local',
    [string]$Target,
    [switch]$Managed,
    [string]$Config
)

$ErrorActionPreference = 'Stop'

if ($Managed) {
    $Scope = 'managed'
}

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

