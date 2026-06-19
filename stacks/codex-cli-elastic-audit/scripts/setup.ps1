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

Write-Host '[setup] 1/4 - Agent Audit data streams (logs-agent_audit.user_prompt-default + .tool_call-default)'
& (Join-Path $ComponentsDir 'backends/elastic-audit/scripts/setup-elasticsearch.ps1') -EsUrl $EsUrl 6>&1 | Indent

Write-Host ''
Write-Host '[setup] 2/4 - agent config: .codex/agent-audit.conf (audit delivery)'
& (Join-Path $ComponentsDir 'agents/codex-cli/scripts/render-agent-audit.ps1') -EsUrl $EsUrl -TargetDir $StackDir 6>&1 | Indent

Write-Host ''
Write-Host '[setup] 3/4 - .codex/config.toml: UserPromptSubmit + PostToolUse Agent Audit hooks (render-hooks), then Elasticsearch MCP appended (render-mcp)'
& (Join-Path $ComponentsDir 'agents/codex-cli/scripts/render-hooks.ps1') -TargetDir $StackDir 6>&1 | Indent
& (Join-Path $ComponentsDir 'agents/codex-cli/scripts/render-mcp.ps1') -TargetDir $StackDir 6>&1 | Indent

Write-Host ''
Write-Host '[setup] 4/4 - Kibana saved objects: Agent Audit data views + saved searches'
& (Join-Path $ComponentsDir 'backends/elastic-audit/scripts/setup-kibana.ps1') -KibanaUrl $KibanaUrl 6>&1 | Indent

Write-Host ''
Write-Host "[setup] done - point a Codex session at this directory (see ../README.md); verify with scripts/verify-agent-audit.ps1 and scripts/verify-tool-call-audit.ps1."


