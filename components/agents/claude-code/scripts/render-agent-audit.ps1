[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EsUrl,
    [Parameter(Mandatory = $true)][string]$TargetDir
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path (Join-Path $ComponentDir 'templates') 'agent-audit.template.conf'

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

$config = Join-Path $TargetDir '.claude/agent-audit.conf'
if (Test-Path -LiteralPath $config) {
    Write-Host "kept existing $config (delete to regenerate)"
    exit 0
}

$content = (Get-Content -Raw -LiteralPath $Template) -replace '@@ES_URL@@', $EsUrl
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $config) | Out-Null
[System.IO.File]::WriteAllText($config, $content, [System.Text.UTF8Encoding]::new($false))
Write-Host "wrote $config"


