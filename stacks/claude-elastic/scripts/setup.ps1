[CmdletBinding()]
param(
    [string]$Scope = 'local',
    [string]$Target
)

$ErrorActionPreference = 'Stop'
$StackDir = Split-Path -Parent $PSScriptRoot
$Manifest = Join-Path $StackDir '../../components/agent-config/Cargo.toml'

& (Join-Path $PSScriptRoot 'provision.ps1')

Write-Host ''

$placeArgs = @('place', '--agent', 'claude', '--config', (Join-Path $StackDir 'agent-config.toml'), '--scope', $Scope)
if ($Target) { $placeArgs += @('--target', $Target) }
cargo run -q --manifest-path $Manifest -- @placeArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
