[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EsUrl,
    [Parameter(Mandatory = $true)][string]$TargetDir
)

$ErrorActionPreference = 'Stop'

$config = Join-Path $TargetDir '.codex/agent-audit.conf'

if (Test-Path -LiteralPath $config) {
    Write-Host "Skipped: $config already exists (delete to regenerate)"
    exit 0
}

$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path (Join-Path $ComponentDir 'templates') 'agent-audit.template.conf'

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

$content = (Get-Content -Raw -LiteralPath $Template) -replace '@@ES_URL@@', $EsUrl
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $config) | Out-Null
[System.IO.File]::WriteAllText($config, $content, [System.Text.UTF8Encoding]::new($false))
