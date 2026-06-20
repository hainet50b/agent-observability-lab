# verify-tool-call-audit.ps1 — codex-cli-elastic-audit Agent Audit tool-call verification
# (PowerShell mirror of verify-tool-call-audit.sh; see that file's header for the
# full rationale). Verifies the DIRECT Agent Audit tool-call path (PostToolUse hook
# -> logs-agent_audit.tool_call-default), not the OTLP/APM path. 3A pattern:
#   Arrange — stack up + wait for Elasticsearch healthy; require setup.ps1 to have
#             rendered .codex/config.toml (inline [[hooks.*]]) and .codex/agent-audit.conf.
#   Act     — feed a synthetic PostToolUse payload (unique session_id, an object
#             tool_input + string tool_response) on stdin to the configured hook
#             (agent-audit.ps1 -Stream tool_call), with CODEX_HOME=<stack>/.codex.
#   Assert  — poll logs-agent_audit.tool_call-default for the document, then check
#             the tool identity, serialized I/O bodies, and identity envelope.
#   Cleanup — delete the synthetic document, then print PASS.
#
# Fail-open note: the hook always exits 0 (never blocks a tool call), so the signal
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
$DataStream = 'logs-agent_audit.tool_call-default'

# .NET's HTTP client stalls ~2s on the localhost IPv6 (::1) attempt before IPv4
# fallback (the same quirk the hook works around); use 127.0.0.1 for this script's
# own ES polling so the verification is fast.
$EsApi = $EsUrl.TrimEnd('/') -replace '://localhost([:/]|$)', '://127.0.0.1$1'

$ScriptDir = Split-Path -Parent $PSCommandPath
$StackDir  = Split-Path -Parent $ScriptDir
$RepoRoot  = Split-Path -Parent (Split-Path -Parent $StackDir)
$HookPs1   = Join-Path $RepoRoot 'components/agents/codex-cli/hooks/agent-audit.ps1'
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
# Confirm the hook is registered on PostToolUse: the inline [[hooks.PostToolUse]]
# table is present in config.toml.
if (-not (Select-String -SimpleMatch -Quiet -Pattern '[[hooks.PostToolUse]]' -LiteralPath (Join-Path $CodexHome 'config.toml'))) {
    Fail 'no [[hooks.PostToolUse]] registered in .codex/config.toml'
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
    $cid = "aol-verify-tc-$([int][double]::Parse((Get-Date -UFormat %s)))-$PID"
    Write-Host "[act] feeding a synthetic PostToolUse payload (conversation_id=$cid) through the configured hook…"

    # Object tool_input + string tool_response (the heterogeneous shapes the hook
    # serializes); cwd/transcript_path/permission_mode confirm the strict mapping drops them.
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

    $env:CODEX_HOME = $CodexHome
    $conf = Join-Path $CodexHome 'agent-audit.conf'
    try { $payload | & pwsh -NoProfile -File $HookPs1 -Stream tool_call -Config $conf } finally { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue }

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

    $search = @{ size = 1; query = @{ term = @{ 'agent_audit.conversation_id' = $cid } } } | ConvertTo-Json -Compress
    $hit = (Invoke-RestMethod -Method Post -TimeoutSec 10 `
            -Uri "$EsApi/$DataStream/_search?ignore_unavailable=true&allow_no_indices=true" `
            -Headers @{ 'Content-Type' = 'application/json' } -Body $search).hits.hits[0]._source
    $tc = $hit.agent_audit.tool_call
    Write-Host "[assert] document: action=$($hit.event.action) tool=$($tc.tool.name) call_id=$($tc.tool.call_id) input.length=$($tc.input.length) output.length=$($tc.output.length)"

    if ($hit.event.action -ne 'tool-call')                 { Fail "event.action is not 'tool-call'" }
    if ($hit.event.dataset -ne 'agent_audit.tool_call')    { Fail "event.dataset is not 'agent_audit.tool_call'" }
    if ($tc.tool.name -ne 'Bash')                          { Fail 'tool.name not captured' }
    if ($tc.tool.call_id -ne 'call_verify_0001')           { Fail 'tool.call_id not captured (tool_use_id mapping)' }

    if (-not $tc.input.text)  { Fail 'input.text empty — tool_input not serialized (plaintext mode expected)' }
    if ($tc.input.text -notmatch 'command') { Fail 'input.text does not look like serialized tool_input JSON' }
    if ([int]$tc.input.length -le 0)  { Fail 'input.length not recorded' }
    if (-not $tc.output.text) { Fail 'output.text empty — tool_response not serialized (plaintext mode expected)' }
    if ([int]$tc.output.length -le 0) { Fail 'output.length not recorded' }
    Write-Host "[assert] tool I/O serialized to .text with lengths (input=$($tc.input.length), output=$($tc.output.length)) ✓"

    if (-not $hit.host.hostname) { Fail 'audit document missing host.hostname — host enrichment or mapping not applied' }
    if (-not $hit.user.id)       { Fail 'audit document missing user.id — identity derivation not applied' }
    $agentProps = $hit.agent_audit.agent.PSObject.Properties.Name
    if (($agentProps -notcontains 'account') -or ($agentProps -notcontains 'organization')) {
        Fail 'audit document missing agent_audit.agent.account/organization — identity schema not applied'
    }
    Write-Host "[assert] identity present (user.id=$($hit.user.id), host.hostname=$($hit.host.hostname), account/organization envelope) ✓"

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
    Write-Host "PASS: Codex PostToolUse hook -> $DataStream delivery verified."
}
finally {
    Pop-Location
}
