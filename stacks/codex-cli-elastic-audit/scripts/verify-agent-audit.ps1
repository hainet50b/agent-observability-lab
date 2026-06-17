#!/usr/bin/env pwsh
# verify-agent-audit.ps1 — codex-cli-elastic-audit Agent Audit delivery verification
# (PowerShell mirror of verify-agent-audit.sh; see that file's header for the full
# rationale). Verifies the DIRECT Agent Audit path (UserPromptSubmit hook ->
# Elasticsearch), not the OTLP/APM path. 3A pattern:
#   Arrange — stack up + wait for Elasticsearch healthy; require setup.ps1 to have
#             rendered .codex/config.toml (inline [[hooks.*]]) and .codex/agent-audit.conf.
#   Act     — feed a synthetic UserPromptSubmit payload (unique session_id) on
#             stdin to the configured hook (capture-user-prompt.ps1), with
#             CODEX_HOME=<stack>/.codex so it reads this stack's delivery config.
#   Assert  — poll logs-agent_audit.user_prompt-default for the document.
#   Cleanup — delete the synthetic document, then print PASS.
#
# Fail-open note: the hook always exits 0 (never blocks a prompt), so the signal
# is the ASSERTION (doc present in ES), not the hook's exit code.
#
# The hook is invoked as a real child `pwsh` process so the payload reaches its
# stdin ([Console]::In.ReadToEnd()) — piping a PowerShell variable straight to
# `& script.ps1` would hang, because the script reads the process stdin, which is
# how Codex actually drives it.
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
$StackDir  = Split-Path -Parent $ScriptDir
$RepoRoot  = Split-Path -Parent (Split-Path -Parent $StackDir)
$HookPs1   = Join-Path $RepoRoot 'components/agents/codex-cli/hooks/capture-user-prompt.ps1'
$CodexHome = Join-Path $StackDir '.codex'

function Skip($m) { Write-Host "SKIP: $m"; exit 0 }
function Fail($m) { [Console]::Error.WriteLine("FAIL: $m"); exit 1 }

# --- Preconditions ---------------------------------------------------------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Skip 'docker CLI not found' }
try { docker info *> $null; if ($LASTEXITCODE -ne 0) { Skip 'docker daemon not reachable; nothing to verify' } }
catch { Skip 'docker daemon not reachable; nothing to verify' }
if (-not (Test-Path -LiteralPath $HookPs1)) { Fail "hook not found: $HookPs1" }
if (-not (Test-Path -LiteralPath (Join-Path $CodexHome 'config.toml')))       { Skip 'no .codex/config.toml — run scripts/setup.ps1 first' }
if (-not (Test-Path -LiteralPath (Join-Path $CodexHome 'agent-audit.conf'))) { Skip 'no .codex/agent-audit.conf — run scripts/setup.ps1 first' }
# Confirm the hook is registered on UserPromptSubmit: the inline
# [[hooks.UserPromptSubmit]] table is present in config.toml.
if (-not (Select-String -SimpleMatch -Quiet -Pattern '[[hooks.UserPromptSubmit]]' -LiteralPath (Join-Path $CodexHome 'config.toml'))) {
    Fail 'no [[hooks.UserPromptSubmit]] registered in .codex/config.toml'
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

    # Shaped like Codex's real UserPromptSubmit payload; cwd/transcript_path are
    # included to confirm the strict mapping drops them.
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

    # Invoke the configured hook as a real child pwsh process with CODEX_HOME set,
    # so the payload reaches its stdin and it reads the rendered agent-audit.conf.
    # Fail-open: it always exits 0; the assertion below is the signal.
    $env:CODEX_HOME = $CodexHome
    try { $payload | & pwsh -NoProfile -File $HookPs1 } finally { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue }

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
        } catch { Write-Verbose "fail-open: $_" }
        Start-Sleep -Seconds 2
    }
    if (-not $landed) { Fail "no audit document landed in $DataStream for conversation_id=$cid within timeout" }

    # Informational: show the canonical document that landed.
    $search = @{ size = 1; query = @{ term = @{ 'agent_audit.conversation_id' = $cid } } } | ConvertTo-Json -Compress
    $hit = (Invoke-RestMethod -Method Post -TimeoutSec 10 `
            -Uri "$EsApi/$DataStream/_search?ignore_unavailable=true&allow_no_indices=true" `
            -Headers @{ 'Content-Type' = 'application/json' } -Body $search).hits.hits[0]._source
    Write-Host "[assert] document: action=$($hit.event.action) host.name=$($hit.host.name) host.hostname=$($hit.host.hostname) provider=$($hit.agent_audit.agent.provider) model=$($hit.agent_audit.agent.model) user_prompt.length=$($hit.agent_audit.user_prompt.length)"
    # Host-enrichment assertion: host.name/host.hostname must be present (added to
    # the strict mapping and emitted by the hook).
    if (-not $hit.host.hostname) { Fail 'audit document missing host.hostname — host enrichment or mapping not applied' }
    Write-Host "[assert] host enrichment present (host.hostname=$($hit.host.hostname)) ✓"

    # Identity schema (SPEC update): provider account/organization envelope present,
    # and user.email gone.
    $agentProps = $hit.agent_audit.agent.PSObject.Properties.Name
    if (($agentProps -notcontains 'account') -or ($agentProps -notcontains 'organization')) {
        Fail 'audit document missing agent_audit.agent.account/organization — identity schema not applied'
    }
    if ($hit.user.PSObject.Properties.Name -contains 'email') {
        Fail 'audit document still carries user.email — identity schema not applied'
    }
    Write-Host '[assert] identity schema applied (account/organization present, no user.email) ✓'

    # Identity derivation (SPEC "Identity derivation"): user.id is the
    # domain-qualified workstation login, always derivable via whoami; account.id is
    # read from CODEX_HOME/auth.json and populated only when that ChatGPT-auth file
    # exists (API-key auth / no file -> null is valid, so only assert when present).
    if (-not $hit.user.id) { Fail 'audit document missing user.id — identity derivation not applied' }
    Write-Host "[assert] user.id derived (user.id=$($hit.user.id)) ✓"

    $authFile = Join-Path $CodexHome 'auth.json'
    if (Test-Path -LiteralPath $authFile) {
        if (-not $hit.agent_audit.agent.account.id) {
            Fail 'auth.json present but agent_audit.agent.account.id not populated — provider identity derivation not applied'
        }
        Write-Host "[assert] provider account.id derived from $authFile (account.id=$($hit.agent_audit.agent.account.id)) ✓"
    } else {
        Write-Host "[assert] no $authFile — skipping provider account.id assertion (API-key auth / null is valid)"
    }

    # --- Cleanup ---------------------------------------------------------------
    Write-Host '[cleanup] removing the synthetic verification document…'
    $del = Invoke-RestMethod -Method Post -TimeoutSec 30 `
        -Uri "$EsApi/$DataStream/_delete_by_query?refresh=true&ignore_unavailable=true" `
        -Headers @{ 'Content-Type' = 'application/json' } -Body $query
    Write-Host "[cleanup] deleted $($del.deleted) document(s)"

    Write-Host ''
    Write-Host "PASS: Codex UserPromptSubmit hook -> $DataStream delivery verified."
}
finally {
    Pop-Location
}

