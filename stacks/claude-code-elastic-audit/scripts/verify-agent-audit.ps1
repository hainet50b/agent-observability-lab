#!/usr/bin/env pwsh
# verify-agent-audit.ps1 — claude-code-elastic-audit Agent Audit delivery verification
# (PowerShell mirror of verify-agent-audit.sh; see that file's header for the full
# rationale). Verifies the DIRECT Agent Audit path (UserPromptSubmit hook ->
# Elasticsearch), not the OTLP/APM path. 3A pattern:
#   Arrange — stack up + wait for Elasticsearch healthy; require setup.ps1 to have
#             rendered .claude/settings.local.json (hooks.UserPromptSubmit) and
#             .claude/agent-audit.conf.
#   Act     — feed a synthetic UserPromptSubmit payload (unique session_id) on
#             stdin to the RENDERED hook exactly as Claude spawns it — read the
#             command + args[] straight from .claude/settings.local.json and run
#             that process. (Driving capture-prompt.ps1 directly would not catch a
#             broken rendered hook command, e.g. a non-exec-form hook Git Bash
#             cannot run on Windows — the class of gap this verification guards.)
#   Assert  — poll logs-agent_audit.user_prompt-default for the document.
#   Cleanup — delete the synthetic document, then print PASS.
#
# Fail-open note: the hook always exits 0 (never blocks a prompt), so the signal
# is the ASSERTION (doc present in ES), not the hook's exit code.
#
# The hook is spawned as the rendered command/args (on Windows, exec form:
# `powershell -NoProfile … -File capture-prompt.ps1 --config <conf>`), a real child
# process, so the payload reaches its stdin ([Console]::In.ReadToEnd()) exactly as
# Claude drives it.
#
# Prereqs: docker (+ daemon), pwsh. SKIP (exit 0) if the daemon is unreachable or
# setup has not run. Override the ES endpoint with -EsUrl.

[CmdletBinding()]
param(
    [string]$EsUrl = 'http://localhost:9200'
)

$ErrorActionPreference = 'Stop'
$DataStream = 'logs-agent_audit.user_prompt-default'

# .NET's HTTP client stalls ~2s on the localhost IPv6 (::1) attempt before IPv4
# fallback (the same quirk the hook works around); use 127.0.0.1 for this script's
# own ES polling so the verification is fast. The hook reads its own URL from
# agent-audit.conf and applies the same rewrite internally.
$EsApi = $EsUrl.TrimEnd('/') -replace '://localhost([:/]|$)', '://127.0.0.1$1'

$ScriptDir = Split-Path -Parent $PSCommandPath
$StackDir = Split-Path -Parent $ScriptDir
$RepoRoot = Split-Path -Parent (Split-Path -Parent $StackDir)
$HookPs1 = Join-Path $RepoRoot 'components/agents/claude-code/hooks/capture-prompt.ps1'
$ClaudeHome = Join-Path $StackDir '.claude'
$Settings = Join-Path $ClaudeHome 'settings.local.json'

function Skip($m) { Write-Host "SKIP: $m"; exit 0 }
function Fail($m) { [Console]::Error.WriteLine("FAIL: $m"); exit 1 }

# --- Preconditions ---------------------------------------------------------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Skip 'docker CLI not found' }
try { docker info *> $null; if ($LASTEXITCODE -ne 0) { Skip 'docker daemon not reachable; nothing to verify' } }
catch { Skip 'docker daemon not reachable; nothing to verify' }
if (-not (Test-Path -LiteralPath $HookPs1)) { Fail "hook not found: $HookPs1" }
if (-not (Test-Path -LiteralPath $Settings)) { Skip 'no .claude/settings.local.json — run scripts/setup.ps1 first' }
if (-not (Test-Path -LiteralPath (Join-Path $ClaudeHome 'agent-audit.conf'))) { Skip 'no .claude/agent-audit.conf — run scripts/setup.ps1 first' }
# Confirm the hook is registered on UserPromptSubmit in settings.local.json.
if (-not ((Get-Content -Raw -LiteralPath $Settings | ConvertFrom-Json).hooks.UserPromptSubmit)) {
    Fail 'no hooks.UserPromptSubmit registered in .claude/settings.local.json'
}

Push-Location $StackDir
try {
    # --- Arrange ---------------------------------------------------------------
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

    # --- Act -------------------------------------------------------------------
    $cid = "aol-verify-$([int][double]::Parse((Get-Date -UFormat %s)))-$PID"
    Write-Host "[act] feeding a synthetic UserPromptSubmit payload (conversation_id=$cid) through the configured hook…"

    # Shaped like Claude's real UserPromptSubmit payload; cwd/transcript_path are
    # included to confirm the strict mapping drops them. No turn_id, no model.
    $payload = [ordered]@{
        session_id      = $cid
        prompt          = 'agent audit verification prompt'
        cwd             = '/should/not/be/sent'
        transcript_path = '/should/not/be/sent.jsonl'
        hook_event_name = 'UserPromptSubmit'
        permission_mode = 'default'
    } | ConvertTo-Json -Compress

    # Spawn the hook EXACTLY as Claude does: read the rendered command + args[] from
    # settings.local.json and run that process with the payload on stdin (the config
    # path is already baked into the rendered args). Fail-open: it always exits 0;
    # the assertion below is the signal.
    $entry = (Get-Content -Raw -LiteralPath $Settings | ConvertFrom-Json).hooks.UserPromptSubmit[0].hooks[0]
    $hookArgs = if ($entry.PSObject.Properties.Name -contains 'args') { @($entry.args) } else { @() }
    Write-Host "[act] spawning the rendered hook: $($entry.command) $($hookArgs -join ' ')"
    $payload | & $entry.command @hookArgs

    # --- Assert ----------------------------------------------------------------
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

    # Informational + assertions on the canonical document that landed.
    $search = @{ size = 1; query = @{ term = @{ 'agent_audit.conversation_id' = $cid } } } | ConvertTo-Json -Compress
    $hit = (Invoke-RestMethod -Method Post -TimeoutSec 10 `
            -Uri "$EsApi/$DataStream/_search?ignore_unavailable=true&allow_no_indices=true" `
            -Headers @{ 'Content-Type' = 'application/json' } -Body $search).hits.hits[0]._source
    Write-Host "[assert] document: action=$($hit.event.action) host.hostname=$($hit.host.hostname) provider=$($hit.agent_audit.agent.provider) name=$($hit.agent_audit.agent.name) turn_id=$($hit.agent_audit.turn_id) user_prompt.length=$($hit.agent_audit.user_prompt.length)"

    # Agent constants: provider=anthropic, name=claude-code, turn_id null, no model.
    if ($hit.agent_audit.agent.provider -ne 'anthropic') { Fail 'agent_audit.agent.provider != anthropic' }
    if ($hit.agent_audit.agent.name -ne 'claude-code') { Fail 'agent_audit.agent.name != claude-code' }
    if ($null -ne $hit.agent_audit.turn_id) { Fail 'agent_audit.turn_id is not null (Claude payload has no turn id)' }
    if ($hit.agent_audit.agent.PSObject.Properties.Name -contains 'model') {
        Fail 'audit document carries agent_audit.agent.model — model should be removed from the schema'
    }
    Write-Host '[assert] agent constants ok (anthropic/claude-code, turn_id null, no model) ✓'

    # Host-enrichment assertion: host.name/host.hostname present.
    if (-not $hit.host.hostname) { Fail 'audit document missing host.hostname — host enrichment or mapping not applied' }
    Write-Host "[assert] host enrichment present (host.hostname=$($hit.host.hostname)) ✓"

    # Identity schema: provider account/organization envelope present, no user.email.
    $agentProps = $hit.agent_audit.agent.PSObject.Properties.Name
    if (($agentProps -notcontains 'account') -or ($agentProps -notcontains 'organization')) {
        Fail 'audit document missing agent_audit.agent.account/organization — identity schema not applied'
    }
    if ($hit.user.PSObject.Properties.Name -contains 'email') {
        Fail 'audit document carries user.email — identity schema not applied'
    }
    Write-Host '[assert] identity schema applied (account/organization present, no user.email) ✓'

    # Identity derivation: user.id is the workstation login, always derivable via whoami.
    if (-not $hit.user.id) { Fail 'audit document missing user.id — identity derivation not applied' }
    Write-Host "[assert] user.id derived (user.id=$($hit.user.id)) ✓"

    # Provider account.id is read from ~/.claude.json's oauthAccount; populated only
    # for an OAuth session (API-key / unauthenticated -> null is valid; informational).
    if ($hit.agent_audit.agent.account.id) {
        Write-Host "[assert] provider account.id derived from ~/.claude.json (account.id=$($hit.agent_audit.agent.account.id)) ✓"
    }
    else {
        Write-Host '[assert] account.id null — no OAuth session in ~/.claude.json (valid; user.id still derived)'
    }

    # --- Cleanup ---------------------------------------------------------------
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


