#!/usr/bin/env pwsh
# capture-user-prompt.ps1 — Codex CLI UserPromptSubmit audit hook
# (PowerShell mirror of capture-user-prompt.sh; same .sh/.ps1 pairing as the
# repo's other scripts). See that file's header for the full rationale. In
# short: fires once per submitted prompt, reshapes Codex's raw hook payload into
# the canonical `agent_audit.user_prompt` document defined in SPEC/agent-audit.md,
# and POSTs it straight to the local Agent Audit data stream
# `logs-agent_audit.user_prompt-default` (direct-to-Elasticsearch, independent of
# the OTLP/APM pipeline). No sealing: lab `mode = "plaintext"` stores the prompt
# text in plaintext (a future encrypted mode nulls text and uses encrypted_text).
#
# Delivery config is read at run time from agent-audit.toml's [elasticsearch] /
# [audit] blocks (url / data_stream / api_key / timeout_ms / audit.mode). Path:
#   $env:CODEX_AGENT_AUDIT_CONFIG, else ${CODEX_HOME:-$HOME/.codex}/agent-audit.toml
#
# Field mapping (Codex raw payload -> canonical document):
#   .session_id -> agent_audit.conversation_id   .turn_id -> agent_audit.turn_id
#   .model -> agent_audit.agent.model            .prompt  -> agent_audit.prompt.text
#   agent.provider/name are constants; prompt.length is the prompt's char count.
#   user.* is the workstation login identity, best-effort: user.id is the
#   domain-qualified login from `whoami` (DOMAIN\user on Windows, bare login on
#   POSIX); user.name is the short login name; user.email is not used.
#   agent_audit.agent.account.* (id/name/email) + parallel organization.* (id/name)
#   are the AI-agent PROVIDER account/org, read LOCALLY (no network) from
#   $CODEX_HOME/auth.json: account.id from .tokens.account_id; account.email/name
#   from the id_token JWT's email/name claims; organization.id/name from the
#   is_default (fallback: first) organizations entry's .id/.title in the id_token's
#   "https://api.openai.com/auth" claim (payload base64url-decoded, NOT
#   signature-verified). Missing file/claim -> null (API-key auth has no id_token).
#   host.name/host.hostname are the runtime OS hostname (best-effort, both the same
#   value). cwd / transcript_path / permission_mode are dropped (not part of the
#   strict audit schema; cwd is PII).
#
# CONTRACT — must never disturb the Codex session:
#   * Writes NOTHING to stdout (on UserPromptSubmit, exit-0 stdout can be
#     injected into the model context). Diagnostics go to stderr via
#     [Console]::Error so they never reach stdout.
#   * ALWAYS exits 0 (fail-open). Bad payload / missing config / unreachable
#     Elasticsearch / any error leaves the user's prompt unblocked; the POST uses
#     a very short timeout so an unavailable destination never delays the session.

$ErrorActionPreference = 'Stop'

function Log($m) { [Console]::Error.WriteLine("[capture-user-prompt] $m") }

# Read a flat TOML scalar by key, unquoted. Keys are unique across the
# [elasticsearch] / [audit] sections, so a section-agnostic lookup is unambiguous.
function Get-TomlValue($lines, $key) {
    foreach ($line in $lines) {
        if ($line -match "^\s*$([regex]::Escape($key))\s*=\s*(.+?)\s*$") {
            $v = $Matches[1]
            if ($v -match '^"(.*)"$' -or $v -match "^'(.*)'$") { return $Matches[1] }
            return $v
        }
    }
    return $null
}

# Decode a base64url string (JWT segment) to its UTF-8 text. Translates the
# url-safe alphabet back to standard base64 and restores padding.
function ConvertFrom-Base64Url($s) {
    $t = $s.Replace('-', '+').Replace('_', '/')
    switch ($t.Length % 4) { 2 { $t += '==' } 3 { $t += '=' } }
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($t))
}

# Best-effort AI-agent PROVIDER identity from $CODEX_HOME/auth.json (no network).
# Returns an object with account_id/account_email/account_name/org_id/org_name;
# any missing file/claim leaves that field $null. Never throws (fail-open).
function Get-CodexProviderIdentity($codexHome) {
    $r = [ordered]@{ account_id = $null; account_email = $null; account_name = $null; org_id = $null; org_name = $null }
    try {
        $authFile = Join-Path $codexHome 'auth.json'
        if (-not (Test-Path -LiteralPath $authFile)) { return $r }
        $auth = Get-Content -Raw -LiteralPath $authFile | ConvertFrom-Json
        $r.account_id = $auth.tokens.account_id
        $idt = $auth.tokens.id_token
        if ($idt) {
            $parts = ([string]$idt).Split('.')
            if ($parts.Length -ge 2) {
                $claims = ConvertFrom-Base64Url $parts[1] | ConvertFrom-Json
                $r.account_email = $claims.email
                $r.account_name  = $claims.name
                $orgs = $claims.'https://api.openai.com/auth'.organizations
                if ($orgs) {
                    $org = $orgs | Where-Object { $_.is_default -eq $true } | Select-Object -First 1
                    if (-not $org) { $org = $orgs | Select-Object -First 1 }
                    if ($org) { $r.org_id = $org.id; $r.org_name = $org.title }
                }
            }
        }
    } catch { }
    return $r
}

try {
    $configFile = if ($env:CODEX_AGENT_AUDIT_CONFIG) {
        $env:CODEX_AGENT_AUDIT_CONFIG
    } else {
        $base = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
        Join-Path $base 'agent-audit.toml'
    }

    if (-not (Test-Path -LiteralPath $configFile)) {
        Log "no delivery config at $configFile — skipping (run setup.ps1)"; exit 0
    }

    $cfgLines    = Get-Content -LiteralPath $configFile
    $esUrl       = Get-TomlValue $cfgLines 'url'
    $dataStream  = Get-TomlValue $cfgLines 'data_stream'
    $apiKey      = Get-TomlValue $cfgLines 'api_key'
    $timeoutMs   = Get-TomlValue $cfgLines 'timeout_ms'
    $mode        = Get-TomlValue $cfgLines 'mode'

    if (-not $esUrl -or -not $dataStream) {
        Log 'config missing url/data_stream — skipping'; exit 0
    }

    $timeoutSec = 0.3
    if ($timeoutMs -match '^\d+$') { $timeoutSec = [int]$timeoutMs / 1000.0 }

    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { Log 'empty stdin — nothing to capture'; exit 0 }

    $rawObj = $null
    try { $rawObj = $raw | ConvertFrom-Json } catch {
        Log 'payload not valid JSON — cannot shape audit document; skipping'; exit 0
    }

    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    # Best-effort runtime identity (Codex's payload has none).
    $userName = if ($env:USER) { $env:USER } elseif ($env:USERNAME) { $env:USERNAME } else { [Environment]::UserName }
    if (-not $userName) { $userName = $null }
    # user.id is the domain-qualified workstation login (whoami: DOMAIN\user on
    # Windows, bare login on POSIX). Empty -> null.
    $userId = try { ([string](& whoami) 2>$null).Trim() } catch { $null }
    if (-not $userId) { $userId = $null }

    # Best-effort AI-agent PROVIDER identity from $CODEX_HOME/auth.json (no network).
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    $ident = Get-CodexProviderIdentity $codexHome

    # Best-effort runtime host (ECS host.hostname/host.name). name == hostname here
    # (best-effort); a richer source could split FQDN vs short name.
    $hostName = try { [System.Net.Dns]::GetHostName() } catch { $null }
    if (-not $hostName) { $hostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { $null } }

    $promptText = $rawObj.prompt
    $promptLen  = if ($null -ne $promptText) { ([string]$promptText).Length } else { 0 }

    # plaintext mode carries prompt.text; any other mode nulls it (sealing into
    # encrypted_text is a later increment). length is the true char count regardless.
    $textField = if ($mode -eq 'plaintext') { $promptText } else { $null }

    # Reshape raw Codex payload -> canonical agent_audit.user_prompt document.
    $record = [ordered]@{
        '@timestamp' = $ts
        event = [ordered]@{
            action  = 'user-prompt'
            created = $ts
            dataset = 'agent_audit.user_prompt'
            kind    = 'event'
        }
        user = [ordered]@{
            id    = $userId
            name  = $userName
        }
        host = [ordered]@{
            name     = $hostName
            hostname = $hostName
        }
        agent_audit = [ordered]@{
            agent = [ordered]@{
                provider     = 'openai'
                name         = 'codex-cli'
                model        = $rawObj.model
                account      = [ordered]@{ id = $ident.account_id; name = $ident.account_name; email = $ident.account_email }
                organization = [ordered]@{ id = $ident.org_id; name = $ident.org_name }
            }
            conversation_id = $rawObj.session_id
            turn_id         = $rawObj.turn_id
            prompt = [ordered]@{
                text           = $textField
                encrypted_text = $null
                length         = $promptLen
            }
        }
    }

    # POST to the data stream's _doc endpoint (auto op_type=create for data
    # streams). Send a UTF-8 byte body so multi-byte prompt text is not mangled by
    # Windows PowerShell 5.1 (the fleet default).
    $json    = $record | ConvertTo-Json -Compress -Depth 20
    $bytes   = [System.Text.Encoding]::UTF8.GetBytes($json)
    # .NET's HTTP client resolves `localhost` to IPv6 (::1) first and connects
    # serially, stalling ~2s before falling back to IPv4 — which blows the short
    # timeout_ms and makes every POST to the local lab stack fail (the bash hook's
    # curl avoids this via IPv4 preference). Rewrite a bare localhost host to
    # 127.0.0.1 so delivery behaves like curl. Any other host is left untouched.
    $esBase  = ($esUrl.TrimEnd('/')) -replace '://localhost([:/]|$)', '://127.0.0.1$1'
    $esTarget = $esBase + '/' + $dataStream + '/_doc'
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($apiKey) { $headers['Authorization'] = "ApiKey $apiKey" }

    try {
        Invoke-RestMethod -Method Post -Uri $esTarget -Headers $headers `
            -Body $bytes -TimeoutSec $timeoutSec | Out-Null
        Log "indexed 1 audit document -> $esTarget"
    } catch {
        Log "POST to $esTarget failed ($_) — prompt proceeds uncaptured"
    }
}
catch {
    Log "capture failed ($_) — prompt proceeds uncaptured"
}
exit 0
