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

filter Indent { "  $_" }

Write-Host '[setup] 1/3 - Agent Audit data streams (logs-agent_audit.user_prompt-default + .tool_call-default)'
& (Join-Path $ComponentsDir 'backends/elastic-audit/scripts/setup-elasticsearch.ps1') -EsUrl $EsUrl 6>&1 | Indent

Write-Host ''
Write-Host '[setup] 2/3 - Codex audit config (.codex/agent-audit.conf + UserPromptSubmit/PostToolUse hooks + Elasticsearch MCP)'
& (Join-Path $ComponentsDir 'agents/codex-cli/scripts/setup-audit.ps1') -TargetDir $StackDir -EsUrl $EsUrl 6>&1 | Indent

Write-Host ''
Write-Host '[setup] 3/3 - Kibana saved objects: Agent Audit data views + saved searches'
& (Join-Path $ComponentsDir 'backends/elastic-audit/scripts/setup-kibana.ps1') -KibanaUrl $KibanaUrl 6>&1 | Indent

Write-Host ''
Write-Host "[setup] done - point a Codex session at this directory (see ../README.md); verify with scripts/verify-agent-audit.ps1 and scripts/verify-tool-call-audit.ps1."


