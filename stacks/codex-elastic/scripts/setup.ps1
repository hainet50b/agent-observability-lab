[CmdletBinding()]
param(
    [string]$Scope = 'local',
    [string]$Target,
    [string]$Config
)

$ErrorActionPreference = 'Stop'
$StackDir = Split-Path -Parent $PSScriptRoot
$Manifest = Join-Path $StackDir '../../components/agent-config/Cargo.toml'
if (-not $Config) { $Config = Join-Path $StackDir 'setup.conf' }

& (Join-Path $PSScriptRoot 'setup-backend.ps1') -Config $Config

Write-Host ''

$placeArgs = @('place', '--agent', 'codex', '--config', $Config, '--scope', $Scope)
if ($Target) { $placeArgs += @('--target', $Target) }
cargo run -q --manifest-path $Manifest -- @placeArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
