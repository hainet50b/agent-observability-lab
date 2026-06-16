[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OtlpEndpoint,
    [Parameter(Mandatory = $true)][string]$TargetDir
)

$ErrorActionPreference = 'Stop'

$config = Join-Path $TargetDir '.codex/config.toml'

if (Test-Path -LiteralPath $config) {
    Write-Host "Skipped: $config already exists (delete to regenerate)"
    exit 0
}

$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path $ComponentDir 'config.template.toml'

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

$content = (Get-Content -Raw -LiteralPath $Template) -replace '@@OTLP_ENDPOINT@@', $OtlpEndpoint
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $config) | Out-Null
[System.IO.File]::WriteAllText($config, $content, [System.Text.UTF8Encoding]::new($false))
