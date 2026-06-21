[CmdletBinding()]
param(
    [string]$EsUrl = 'http://localhost:9200'
)

$ErrorActionPreference = 'Stop'
$DataStream = 'logs-agent_audit.user_prompt-default'

# .NET's HTTP client stalls ~2s on localhost IPv6 (::1) before IPv4 fallback; use
# 127.0.0.1 so this script's ES polling is fast.
$EsApi = $EsUrl.TrimEnd('/') -replace '://localhost([:/]|$)', '://127.0.0.1$1'

$ScriptDir = Split-Path -Parent $PSCommandPath
$StackDir = Split-Path -Parent $ScriptDir
$HookPs1 = Join-Path $StackDir '.claude/hooks/agent-audit.ps1'
$ClaudeHome = Join-Path $StackDir '.claude'
$Settings = Join-Path $ClaudeHome 'settings.local.json'

function Skip($m) { Write-Host "SKIP: $m"; exit 0 }
function Fail($m) { [Console]::Error.WriteLine("FAIL: $m"); exit 1 }

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Skip 'docker CLI not found' }
try { docker info *> $null; if ($LASTEXITCODE -ne 0) { Skip 'docker daemon not reachable; nothing to verify' } }
catch { Skip 'docker daemon not reachable; nothing to verify' }
if (-not (Test-Path -LiteralPath $HookPs1)) { Fail "hook not found: $HookPs1" }
if (-not (Test-Path -LiteralPath $Settings)) { Skip 'no .claude/settings.local.json — run scripts/setup.ps1 first' }
if (-not (Test-Path -LiteralPath (Join-Path $ClaudeHome 'agent-audit.conf'))) { Skip 'no .claude/agent-audit.conf — run scripts/setup.ps1 first' }
if (-not ((Get-Content -Raw -LiteralPath $Settings | ConvertFrom-Json).hooks.UserPromptSubmit)) {
    Fail 'no hooks.UserPromptSubmit registered in .claude/settings.local.json'
}

Push-Location $StackDir
try {
    Write-Host '[arrange] bringing the stack up (docker compose up -d)…'
    docker compose up -d
    if ($LASTEXITCODE -ne 0) { Fail 'docker compose up failed' }

    $healthy = $false
    for ($i = 0; $i -lt 60; $i++) {
        $status = (docker inspect -f '{{.State.Health.Status}}' aol-elasticsearch 2>$null)
        if ($status -eq 'healthy') { Write-Host '[arrange] aol-elasticsearch healthy'; $healthy = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $healthy) { docker compose ps; Fail 'aol-elasticsearch did not become healthy' }

    $cid = "aol-verify-$([int][double]::Parse((Get-Date -UFormat %s)))-$PID"
    Write-Host "[act] feeding a synthetic UserPromptSubmit payload (conversation_id=$cid) through the configured hook…"

    $payload = [ordered]@{
        session_id      = $cid
        prompt          = 'agent audit verification prompt'
        cwd             = '/should/not/be/sent'
        transcript_path = '/should/not/be/sent.jsonl'
        hook_event_name = 'UserPromptSubmit'
        permission_mode = 'default'
    } | ConvertTo-Json -Compress

    $entry = (Get-Content -Raw -LiteralPath $Settings | ConvertFrom-Json).hooks.UserPromptSubmit[0].hooks[0]
    $hookArgs = if ($entry.PSObject.Properties.Name -contains 'args') { @($entry.args) } else { @() }
    Write-Host "[act] spawning the rendered hook: $($entry.command) $($hookArgs -join ' ')"
    $payload | & $entry.command @hookArgs

    Write-Host "[assert] querying $DataStream for the audit document…"
    $query = @{ query = @{ term = @{ 'agent_audit.conversation_id' = $cid } } } | ConvertTo-Json -Compress
    $landed = $false
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $r = Invoke-RestMethod -Method Post -TimeoutSec 10 `
                -Uri "$EsApi/$DataStream/_count?ignore_unavailable=true&allow_no_indices=true" `
                -Headers @{ 'Content-Type' = 'application/json' } -Body $query
            if ([int]$r.count -ge 1) {
                Write-Host "[assert] found $($r.count) audit document(s) for conversation_id=$cid ✓"
                $landed = $true; break
            }
        }
        catch { Write-Verbose "fail-open: $_" }
        Start-Sleep -Seconds 2
    }
    if (-not $landed) { Fail "no audit document landed in $DataStream for conversation_id=$cid within timeout" }

    $search = @{ size = 1; query = @{ term = @{ 'agent_audit.conversation_id' = $cid } } } | ConvertTo-Json -Compress
    $hit = (Invoke-RestMethod -Method Post -TimeoutSec 10 `
            -Uri "$EsApi/$DataStream/_search?ignore_unavailable=true&allow_no_indices=true" `
            -Headers @{ 'Content-Type' = 'application/json' } -Body $search).hits.hits[0]._source
    Write-Host "[assert] document: action=$($hit.event.action) host.hostname=$($hit.host.hostname) provider=$($hit.agent_audit.agent.provider) name=$($hit.agent_audit.agent.name) turn_id=$($hit.agent_audit.turn_id) user_prompt.length=$($hit.agent_audit.user_prompt.length)"

    if ($hit.agent_audit.agent.provider -ne 'anthropic') { Fail 'agent_audit.agent.provider != anthropic' }
    if ($hit.agent_audit.agent.name -ne 'claude-code') { Fail 'agent_audit.agent.name != claude-code' }
    if ($null -ne $hit.agent_audit.turn_id) { Fail 'agent_audit.turn_id is not null (Claude payload has no turn id)' }
    if ($hit.agent_audit.agent.PSObject.Properties.Name -contains 'model') {
        Fail 'audit document carries agent_audit.agent.model — model should be removed from the schema'
    }
    Write-Host '[assert] agent constants ok (anthropic/claude-code, turn_id null, no model) ✓'

    if (-not $hit.host.hostname) { Fail 'audit document missing host.hostname — host enrichment or mapping not applied' }
    Write-Host "[assert] host enrichment present (host.hostname=$($hit.host.hostname)) ✓"

    $agentProps = $hit.agent_audit.agent.PSObject.Properties.Name
    if (($agentProps -notcontains 'account') -or ($agentProps -notcontains 'organization')) {
        Fail 'audit document missing agent_audit.agent.account/organization — identity schema not applied'
    }
    if ($hit.user.PSObject.Properties.Name -contains 'email') {
        Fail 'audit document carries user.email — identity schema not applied'
    }
    Write-Host '[assert] identity schema applied (account/organization present, no user.email) ✓'

    if (-not $hit.user.id) { Fail 'audit document missing user.id — identity derivation not applied' }
    Write-Host "[assert] user.id derived (user.id=$($hit.user.id)) ✓"

    if ($hit.agent_audit.agent.account.id) {
        Write-Host "[assert] provider account.id derived from ~/.claude.json (account.id=$($hit.agent_audit.agent.account.id)) ✓"
    }
    else {
        Write-Host '[assert] account.id null — no OAuth session in ~/.claude.json (valid; user.id still derived)'
    }

    Write-Host '[cleanup] removing the synthetic verification document…'
    $del = Invoke-RestMethod -Method Post -TimeoutSec 30 `
        -Uri "$EsApi/$DataStream/_delete_by_query?refresh=true&ignore_unavailable=true" `
        -Headers @{ 'Content-Type' = 'application/json' } -Body $query
    Write-Host "[cleanup] deleted $($del.deleted) document(s)"

    Write-Host ''
    Write-Host "PASS: Claude Code UserPromptSubmit hook -> $DataStream delivery verified."
}
finally {
    Pop-Location
}
