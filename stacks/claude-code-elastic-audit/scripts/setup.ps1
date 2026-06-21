[CmdletBinding()]
param(
    [string]$Config
)

$ErrorActionPreference = 'Stop'

$StackDir = Split-Path -Parent $PSScriptRoot
$ComponentsDir = Join-Path $PSScriptRoot '../../../components'

if (-not $Config) {
    $Config = Join-Path $StackDir 'setup.conf'
}
if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) {
    [Console]::Error.WriteLine("FAIL: config file not found: $Config")
    exit 2
}

foreach ($line in Get-Content -LiteralPath $Config) {
    if ($line -match '^\s*#' -or $line -notmatch '=') {
        continue
    }
    $k, $v = $line -split '=', 2
    switch ($k.Trim()) {
        'elasticsearch.url' {
            $EsUrl = $v.Trim()
        }
        'kibana.url' {
            $KibanaUrl = $v.Trim()
        }
    }
}
foreach ($req in @{ 'elasticsearch.url' = $EsUrl; 'kibana.url' = $KibanaUrl }.GetEnumerator()) {
    if (-not $req.Value) {
        [Console]::Error.WriteLine("FAIL: ${Config}: missing or empty key '$($req.Key)'.")
        exit 2
    }
}

$env:ES_URL = $EsUrl
$env:KIBANA_URL = $KibanaUrl

filter Indent { "  $_" }

Write-Host '[setup] 1/3 - Agent Audit data streams'
& (Join-Path $ComponentsDir 'backends/elastic-audit/scripts/setup-elasticsearch.ps1') 6>&1 | Indent

Write-Host ''
Write-Host '[setup] 2/3 - Claude Code audit config'
& (Join-Path $ComponentsDir 'agents/claude-code/scripts/setup-audit.ps1') -TargetDir $StackDir -EsUrl $EsUrl 6>&1 | Indent

Write-Host ''
Write-Host '[setup] 3/3 - Kibana saved objects'
& (Join-Path $ComponentsDir 'backends/elastic-audit/scripts/setup-kibana.ps1') 6>&1 | Indent

