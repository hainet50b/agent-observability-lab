[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir
)

$ErrorActionPreference = 'Stop'

$config = Join-Path $TargetDir '.codex/config.toml'

if ((Test-Path -LiteralPath $config) -and (Select-String -LiteralPath $config -SimpleMatch '[mcp_servers.elasticsearch]' -Quiet)) {
    Write-Host "Skipped: $config already has [mcp_servers.elasticsearch]"
    exit 0
}

$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path $ComponentDir 'mcp.template.toml'

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

$block = (Get-Content -Raw -LiteralPath $Template) -replace "`r`n", "`n"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $config) | Out-Null
if (Test-Path -LiteralPath $config) {
    $existing = ((Get-Content -Raw -LiteralPath $config) -replace "`r`n", "`n").TrimEnd("`n")
    $combined = $existing + "`n`n" + $block
} else {
    $combined = $block
}
[System.IO.File]::WriteAllText($config, $combined, [System.Text.UTF8Encoding]::new($false))
