[CmdletBinding()]
param(
    [string]$Workbench = $env:AOL_WORKBENCH,
    [string]$EsUrl = 'http://localhost:9200'
)

$ErrorActionPreference = 'Stop'
$UpStream = 'logs-agent_audit.user_prompt-default'
$TcStream = 'logs-agent_audit.tool_call-default'

# .NET's HTTP client stalls ~2s on localhost IPv6 (::1) before IPv4 fallback; use
# 127.0.0.1 so this script's ES polling is fast.
$EsApi = $EsUrl.TrimEnd('/') -replace '://localhost([:/]|$)', '://127.0.0.1$1'

$ScriptDir = Split-Path -Parent $PSCommandPath
if (-not $Workbench) { [Console]::Error.WriteLine('FAIL: usage: verify-agent-audit-codex.ps1 -Workbench <dir>  (or set AOL_WORKBENCH) — the directory agent config was placed into'); exit 1 }
$Workbench = (Resolve-Path -LiteralPath $Workbench).Path
$HookPs1 = Join-Path $Workbench '.codex/hooks/agent-audit.ps1'
$CodexHome = Join-Path $Workbench '.codex'

function Skip($m) { Write-Host "SKIP: $m"; exit 0 }
function Fail($m) { [Console]::Error.WriteLine("FAIL: $m"); exit 1 }

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Skip 'docker CLI not found' }
try { docker info *> $null; if ($LASTEXITCODE -ne 0) { Skip 'docker daemon not reachable; nothing to verify' } }
catch { Skip 'docker daemon not reachable; nothing to verify' }
if (-not (Test-Path -LiteralPath $HookPs1)) { Fail "hook not found: $HookPs1" }
if (-not (Test-Path -LiteralPath (Join-Path $CodexHome 'config.toml'))) { Skip 'no .codex/config.toml in the workbench — run agent-config place first (see README.md)' }
if (-not (Test-Path -LiteralPath (Join-Path $CodexHome 'hooks/agent-audit.conf'))) { Skip 'no .codex/hooks/agent-audit.conf in the workbench — run agent-config place first (see README.md)' }
if (-not (Select-String -SimpleMatch -Quiet -Pattern '[[hooks.UserPromptSubmit]]' -LiteralPath (Join-Path $CodexHome 'config.toml'))) {
    Fail 'no [[hooks.UserPromptSubmit]] registered in .codex/config.toml'
}
if (-not (Select-String -SimpleMatch -Quiet -Pattern '[[hooks.PostToolUse]]' -LiteralPath (Join-Path $CodexHome 'config.toml'))) {
    Fail 'no [[hooks.PostToolUse]] registered in .codex/config.toml'
}

function Invoke-Hook($Stream, $Payload) {
    # Invoke as a real child pwsh process (not & script.ps1, which would hang) so the
    # payload reaches the hook's stdin.
    $env:CODEX_HOME = $CodexHome
    $conf = Join-Path $CodexHome 'hooks/agent-audit.conf'
    try { $Payload | & pwsh -NoProfile -File $HookPs1 -Stream $Stream -Config $conf } finally { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue }
}

function Get-Landed($Stream, $Query, $Cid) {
    Write-Host "[assert] querying $Stream for the audit document…"
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $r = Invoke-RestMethod -Method Post -TimeoutSec 10 `
                -Uri "$EsApi/$Stream/_count?ignore_unavailable=true&allow_no_indices=true" `
                -Headers @{ 'Content-Type' = 'application/json' } -Body $Query
            if ([int]$r.count -ge 1) {
                Write-Host "[assert] found $($r.count) audit document(s) for conversation_id=$Cid ✓"
                return $true
            }
        }
        catch { Write-Verbose "fail-open: $_" }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Get-FullHit($Stream, $Cid) {
    $search = @{ size = 1; query = @{ term = @{ 'agent_audit.conversation_id' = $Cid } } } | ConvertTo-Json -Compress
    return (Invoke-RestMethod -Method Post -TimeoutSec 10 `
            -Uri "$EsApi/$Stream/_search?ignore_unavailable=true&allow_no_indices=true" `
            -Headers @{ 'Content-Type' = 'application/json' } -Body $search).hits.hits[0]
}

function Remove-Doc($Index, $Id) {
    Write-Host '[cleanup] removing the synthetic verification document by id…'
    $del = Invoke-RestMethod -Method Delete -TimeoutSec 30 `
        -Uri "$EsApi/$Index/_doc/$Id?refresh=true"
    Write-Host "[cleanup] deleted $($del._id) (result=$($del.result))"
}

function Test-AccountId($Hit) {
    $authFile = Join-Path $CodexHome 'auth.json'
    if (Test-Path -LiteralPath $authFile) {
        if (-not $Hit.agent_audit.agent.account.id) {
            Fail 'auth.json present but agent_audit.agent.account.id not populated — provider identity derivation not applied'
        }
        Write-Host "[assert] provider account.id derived from $authFile (account.id=$($Hit.agent_audit.agent.account.id)) ✓"
    }
    else {
        Write-Host "[assert] no $authFile — skipping provider account.id assertion (API-key auth / null is valid)"
    }
}

Push-Location $ScriptDir
try {
    Write-Host '[arrange] bringing the backend up (docker compose up -d)…'
    docker compose up -d
    if ($LASTEXITCODE -ne 0) { Fail 'docker compose up failed' }

    $healthy = $false
    for ($i = 0; $i -lt 60; $i++) {
        $status = (docker inspect -f '{{.State.Health.Status}}' aol-elasticsearch 2>$null)
        if ($status -eq 'healthy') { Write-Host '[arrange] aol-elasticsearch healthy'; $healthy = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $healthy) { docker compose ps; Fail 'aol-elasticsearch did not become healthy' }

    # --- user_prompt stream ---

    $cid = "aol-verify-$([int][double]::Parse((Get-Date -UFormat %s)))-$PID"
    Write-Host "[act] feeding a synthetic UserPromptSubmit payload (conversation_id=$cid) through the configured hook…"

    $payload = [ordered]@{
        session_id      = $cid
        turn_id         = 'verify-turn-1'
        model           = 'verify-model'
        prompt          = 'agent audit verification prompt'
        cwd             = '/should/not/be/sent'
        transcript_path = '/should/not/be/sent.jsonl'
        hook_event_name = 'UserPromptSubmit'
        permission_mode = 'auto'
    } | ConvertTo-Json -Compress

    Invoke-Hook 'user_prompt' $payload

    $query = @{ query = @{ term = @{ 'agent_audit.conversation_id' = $cid } } } | ConvertTo-Json -Compress
    if (-not (Get-Landed -Stream $UpStream -Query $query -Cid $cid)) { Fail "no audit document landed in $UpStream for conversation_id=$cid within timeout" }

    $found = Get-FullHit $UpStream $cid
    $hit = $found._source
    Write-Host "[assert] document: action=$($hit.event.action) host.name=$($hit.host.name) host.hostname=$($hit.host.hostname) provider=$($hit.agent_audit.agent.provider) model=$($hit.agent_audit.agent.model) user_prompt.length=$($hit.agent_audit.user_prompt.length)"
    if (-not $hit.host.hostname) { Fail 'audit document missing host.hostname — host enrichment or mapping not applied' }
    Write-Host "[assert] host enrichment present (host.hostname=$($hit.host.hostname)) ✓"

    $agentProps = $hit.agent_audit.agent.PSObject.Properties.Name
    if (($agentProps -notcontains 'account') -or ($agentProps -notcontains 'organization')) {
        Fail 'audit document missing agent_audit.agent.account/organization — identity schema not applied'
    }
    if ($hit.user.PSObject.Properties.Name -contains 'email') {
        Fail 'audit document still carries user.email — identity schema not applied'
    }
    Write-Host '[assert] identity schema applied (account/organization present, no user.email) ✓'

    if (-not $hit.user.id) { Fail 'audit document missing user.id — identity derivation not applied' }
    Write-Host "[assert] user.id derived (user.id=$($hit.user.id)) ✓"

    Test-AccountId $hit

    Remove-Doc $found._index $found._id

    # --- tool_call stream ---

    $cid = "aol-verify-tc-$([int][double]::Parse((Get-Date -UFormat %s)))-$PID"
    Write-Host "[act] feeding a synthetic PostToolUse payload (conversation_id=$cid) through the configured hook…"

    $payload = [ordered]@{
        session_id      = $cid
        turn_id         = 'verify-turn-1'
        model           = 'verify-model'
        tool_name       = 'Bash'
        tool_use_id     = 'call_verify_0001'
        tool_input      = [ordered]@{ command = 'echo hello'; description = 'verify' }
        tool_response   = "hello`n"
        cwd             = '/should/not/be/sent'
        transcript_path = '/should/not/be/sent.jsonl'
        hook_event_name = 'PostToolUse'
        permission_mode = 'auto'
    } | ConvertTo-Json -Compress

    Invoke-Hook 'tool_call' $payload

    $query = @{ query = @{ term = @{ 'agent_audit.conversation_id' = $cid } } } | ConvertTo-Json -Compress
    if (-not (Get-Landed -Stream $TcStream -Query $query -Cid $cid)) { Fail "no audit document landed in $TcStream for conversation_id=$cid within timeout" }

    $found = Get-FullHit $TcStream $cid
    $hit = $found._source
    $tc = $hit.agent_audit.tool_call
    Write-Host "[assert] document: action=$($hit.event.action) tool=$($tc.tool.name) call_id=$($tc.tool.call_id) input.length=$($tc.input.length) output.length=$($tc.output.length)"

    if ($hit.event.action -ne 'tool-call') { Fail "event.action is not 'tool-call'" }
    if ($hit.event.dataset -ne 'agent_audit.tool_call') { Fail "event.dataset is not 'agent_audit.tool_call'" }
    if ($tc.tool.name -ne 'Bash') { Fail 'tool.name not captured' }
    if ($tc.tool.call_id -ne 'call_verify_0001') { Fail 'tool.call_id not captured (tool_use_id mapping)' }

    if (-not $tc.input.text) { Fail 'input.text empty — tool_input not serialized (plaintext mode expected)' }
    if ($tc.input.text -notmatch 'command') { Fail 'input.text does not look like serialized tool_input JSON' }
    if ([int]$tc.input.length -le 0) { Fail 'input.length not recorded' }
    if (-not $tc.output.text) { Fail 'output.text empty — tool_response not serialized (plaintext mode expected)' }
    if ([int]$tc.output.length -le 0) { Fail 'output.length not recorded' }
    Write-Host "[assert] tool I/O serialized to .text with lengths (input=$($tc.input.length), output=$($tc.output.length)) ✓"

    if (-not $hit.host.hostname) { Fail 'audit document missing host.hostname — host enrichment or mapping not applied' }
    if (-not $hit.user.id) { Fail 'audit document missing user.id — identity derivation not applied' }
    $agentProps = $hit.agent_audit.agent.PSObject.Properties.Name
    if (($agentProps -notcontains 'account') -or ($agentProps -notcontains 'organization')) {
        Fail 'audit document missing agent_audit.agent.account/organization — identity schema not applied'
    }
    Write-Host "[assert] identity present (user.id=$($hit.user.id), host.hostname=$($hit.host.hostname), account/organization envelope) ✓"

    Test-AccountId $hit

    Remove-Doc $found._index $found._id

    Write-Host ''
    Write-Host 'PASS: Codex UserPromptSubmit + PostToolUse hooks -> agent_audit stream delivery verified.'
}
finally {
    Pop-Location
}
