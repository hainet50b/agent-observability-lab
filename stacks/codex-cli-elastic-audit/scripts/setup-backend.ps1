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

function Wait-Ready {
    param([string]$Name, [string]$Url)
    $Retries = 30
    $Delay = 2
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
            if ([int]$resp.StatusCode -ge 200 -and [int]$resp.StatusCode -lt 300) {
                Write-Host "$Name ready at $Url (HTTP $([int]$resp.StatusCode))"
                return
            }
        }
        catch {
            # not ready yet (connection refused / 5xx) — retry until the budget runs out
            $null = $_
        }
        Start-Sleep -Seconds $Delay
    }
    [Console]::Error.WriteLine("FAIL: $Name not reachable at $Url — bring the stack up first: docker compose up -d (and wait for healthy), then re-run.")
    exit 1
}

Write-Host '[backend] 1/3 - wait for backend'
Wait-Ready -Name 'Elasticsearch' -Url "$EsUrl/_cluster/health" | Indent
Wait-Ready -Name 'Kibana' -Url "$KibanaUrl/api/status" | Indent

Write-Host ''
Write-Host '[backend] 2/3 - Agent Audit data streams'
& (Join-Path $ComponentsDir 'backends/elastic-audit/scripts/setup-elasticsearch.ps1') 6>&1 | Indent

Write-Host ''
Write-Host '[backend] 3/3 - Kibana saved objects'
& (Join-Path $ComponentsDir 'backends/elastic-audit/scripts/setup-kibana.ps1') 6>&1 | Indent
