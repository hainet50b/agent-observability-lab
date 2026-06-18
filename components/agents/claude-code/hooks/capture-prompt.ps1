#!/usr/bin/env pwsh
# Runs under Windows PowerShell 5.1 (powershell.exe) on the employee fleet — no
# PS7-only syntax. On Windows it is spawned by powershell.exe via the exec-form
# hook (see render-hook.ps1); the pwsh shebang is only for direct execution on
# POSIX (where powershell.exe does not exist) and implies no PS7 runtime requirement.
#
# capture-prompt.ps1 — Claude Code UserPromptSubmit audit hook
# (PowerShell mirror of capture-prompt.sh; same .sh/.ps1 pairing as the repo's
# other scripts). See that file's header for the full rationale. In short: fires
# once per submitted prompt, reshapes Claude's raw hook payload into the canonical
# `agent_audit.user_prompt` document defined in SPEC/agent-audit.md, and POSTs it
# straight to the local Agent Audit data stream (direct-to-Elasticsearch,
# independent of the OTLP/APM pipeline). No sealing: content=plaintext stores the
# prompt text in plaintext (a future encrypted mode nulls text and uses encrypted_text).
#
# Delivery config is read at run time from the flat key=value agent-audit.conf (zero
# external deps — ConvertFrom-StringData, no external JSON CLI / TOML parser; see SPEC/agent-audit.md
# "Delivery and authorization"). This hook reads only the user_prompt stream's keys:
# capture.user_prompt.enabled (false => skip), capture.user_prompt.content (plaintext
# => .text; redacted => [REDACTED] marker; encrypted => null, sealing TBD), plus the
# shared elasticsearch.url / .api_key / .timeout_ms and the per-stream
# elasticsearch.data_stream.user_prompt. Config path:
#   INJECTED via -Config / --config <abs path> from the rendered hook command (no ambient discovery).
#
# Field mapping (Claude raw payload -> canonical document):
#   .session_id -> agent_audit.conversation_id   (no turn id -> agent_audit.turn_id = null)
#   .prompt -> agent_audit.user_prompt.text
#   agent.provider/name are constants ("anthropic"/"claude-code"); prompt.length is
#   the prompt's char count. user.* is the workstation login identity, best-effort:
#   user.id is the domain-qualified login from `whoami` (DOMAIN\user on Windows, bare
#   login on POSIX); user.name is the short login name; user.email is not used.
#   agent_audit.agent.account.* (id/name/email) + parallel organization.* (id/name) are
#   the AI-agent PROVIDER account/org, read LOCALLY (no network) from ~/.claude.json's
#   `oauthAccount` (plain JSON, no JWT): account.id <- accountUuid, account.name <-
#   displayName, account.email <- emailAddress, organization.id <- organizationUuid,
#   organization.name <- organizationName. Missing key/file -> null. host.name/host.hostname
#   are the runtime OS hostname (best-effort, both the same value). cwd / transcript_path /
#   permission_mode are dropped (not in the strict audit schema; cwd is PII).
#
# CONTRACT — must never disturb the Claude session:
#   * Writes NOTHING to stdout (on UserPromptSubmit, exit-0 stdout can be injected
#     into the model context). Diagnostics go to stderr via [Console]::Error.
#   * ALWAYS exits 0 (fail-open). Bad payload / missing config / unreachable
#     Elasticsearch / any error leaves the user's prompt unblocked; the POST uses
#     a very short timeout so an unavailable destination never delays the session.

$ErrorActionPreference = 'Stop'

function Log($m) { [Console]::Error.WriteLine("[capture-prompt] $m") }

# Coerce an empty/whitespace value to $null so the JSON carries null, not "".
function NullIfEmpty($v) { if ([string]::IsNullOrWhiteSpace([string]$v)) { return $null } return [string]$v }

try {
    $stream = 'user_prompt'

    # Config path is INJECTED via -Config / --config (the rendered hook command
    # supplies the absolute agent-audit.conf path). A shipped hook does NOT infer its
    # config from cwd / $HOME — explicit injection only.
    $configFile = $null
    for ($i = 0; $i -lt $args.Count; $i++) {
        if (($args[$i] -eq '-Config' -or $args[$i] -eq '--config') -and $i + 1 -lt $args.Count) {
            $configFile = $args[$i + 1]
        }
    }
    if (-not $configFile) {
        Log 'no -Config <path> provided — skipping (the rendered hook command injects it)'; exit 0
    }

    if (-not (Test-Path -LiteralPath $configFile)) {
        Log "no delivery config at $configFile — skipping (run setup.ps1)"; exit 0
    }

    # Flat key=value config, parsed with the built-in ConvertFrom-StringData (no
    # external JSON CLI / TOML parser). Comment (#) and blank lines are ignored; dotted keys carry the
    # structure. This hook reads only the user_prompt stream's keys.
    $cfg = Get-Content -Raw -LiteralPath $configFile | ConvertFrom-StringData

    if ($cfg["capture.$stream.enabled"] -eq 'false') {
        Log "capture.$stream.enabled=false — skipping (stream disabled)"; exit 0
    }
    $content = $cfg["capture.$stream.content"]
    $esUrl = $cfg['elasticsearch.url']
    $apiKey = $cfg['elasticsearch.api_key']
    $timeoutMs = $cfg['elasticsearch.timeout_ms']
    $dataStream = $cfg["elasticsearch.data_stream.$stream"]

    if (-not $esUrl -or -not $dataStream) {
        Log "config missing elasticsearch.url / data_stream.$stream — skipping"; exit 0
    }

    $timeoutSec = 0.3
    if ($timeoutMs -match '^\d+$') { $timeoutSec = [int]$timeoutMs / 1000.0 }

    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { Log 'empty stdin — nothing to capture'; exit 0 }

    $rawObj = $null
    try { $rawObj = $raw | ConvertFrom-Json } catch {
        Log 'payload not valid JSON — cannot shape audit document; skipping'; exit 0
    }

    $prompt = [string]$rawObj.prompt
    if (-not $prompt) { Log 'no prompt in payload — nothing to capture'; exit 0 }
    $promptLen = $prompt.Length

    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    # Best-effort runtime identity (Claude's payload has none).
    $userName = if ($env:USER) { $env:USER } elseif ($env:USERNAME) { $env:USERNAME } else { [Environment]::UserName }
    $userName = NullIfEmpty $userName
    # user.id is the domain-qualified workstation login (whoami: DOMAIN\user on
    # Windows, bare login on POSIX). Empty -> null.
    $userId = try { ([string](& whoami) 2>$null).Trim() } catch { $null }
    $userId = NullIfEmpty $userId

    $hostName = NullIfEmpty ([System.Net.Dns]::GetHostName())

    # Best-effort AI-agent PROVIDER identity from ~/.claude.json's oauthAccount object
    # (plain JSON, no JWT, no network). Missing file/key -> null.
    $claudeConfig = if ($env:CLAUDE_CONFIG) { $env:CLAUDE_CONFIG } else { Join-Path $HOME '.claude.json' }
    $acctId = $null; $acctName = $null; $acctEmail = $null; $orgId = $null; $orgName = $null
    if (Test-Path -LiteralPath $claudeConfig -PathType Leaf) {
        try {
            $oauth = (Get-Content -Raw -LiteralPath $claudeConfig | ConvertFrom-Json).oauthAccount
            if ($oauth) {
                $acctId = NullIfEmpty $oauth.accountUuid
                $acctName = NullIfEmpty $oauth.displayName
                $acctEmail = NullIfEmpty $oauth.emailAddress
                $orgId = NullIfEmpty $oauth.organizationUuid
                $orgName = NullIfEmpty $oauth.organizationName
            }
        }
        catch { Write-Verbose "fail-open: $_" }
    }

    # Body form by capture.user_prompt.content (true .length kept regardless).
    $textField = switch ($content) {
        'plaintext' { $prompt }
        'redacted' { '[REDACTED]' }
        default { $null }
    }

    $record = [ordered]@{
        '@timestamp' = $ts
        event        = [ordered]@{ action = 'user-prompt'; created = $ts; dataset = 'agent_audit.user_prompt'; kind = 'event' }
        user         = [ordered]@{ id = $userId; name = $userName }
        host         = [ordered]@{ name = $hostName; hostname = $hostName }
        agent_audit  = [ordered]@{
            agent           = [ordered]@{
                provider     = 'anthropic'
                name         = 'claude-code'
                account      = [ordered]@{ id = $acctId; name = $acctName; email = $acctEmail }
                organization = [ordered]@{ id = $orgId; name = $orgName }
            }
            conversation_id = (NullIfEmpty $rawObj.session_id)
            turn_id         = $null
            user_prompt     = [ordered]@{
                text           = $textField
                encrypted_text = $null
                length         = $promptLen
            }
        }
    }

    # POST to the data stream's _doc endpoint (auto op_type=create for data
    # streams). Send a UTF-8 byte body so multi-byte prompt text is not mangled by
    # Windows PowerShell 5.1 (the fleet default).
    $json = $record | ConvertTo-Json -Compress -Depth 20
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    # .NET's HTTP client resolves `localhost` to IPv6 (::1) first and connects
    # serially, stalling ~2s before falling back to IPv4 — which blows the short
    # timeout_ms and makes every POST to the local lab stack fail (the bash hook's
    # curl avoids this via IPv4 preference). Rewrite a bare localhost host to
    # 127.0.0.1 so delivery behaves like curl. Any other host is left untouched.
    $esBase = ($esUrl.TrimEnd('/')) -replace '://localhost([:/]|$)', '://127.0.0.1$1'
    $esTarget = $esBase + '/' + $dataStream + '/_doc'
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($apiKey) { $headers['Authorization'] = "ApiKey $apiKey" }

    try {
        Invoke-RestMethod -Method Post -Uri $esTarget -Headers $headers `
            -Body $bytes -TimeoutSec $timeoutSec | Out-Null
        Log "indexed 1 audit document -> $esTarget"
    }
    catch {
        Log "POST to $esTarget failed ($_) — prompt proceeds uncaptured"
    }
}
catch {
    Log "capture failed ($_) — prompt proceeds uncaptured"
}
exit 0


