#!/usr/bin/env pwsh
# capture-tool-call.ps1 — Codex CLI PostToolUse audit hook
# (PowerShell mirror of capture-tool-call.sh; same .sh/.ps1 pairing as the
# repo's other scripts). See that file's header for the full rationale. In
# short: fires once per completed tool call, reshapes Codex's raw PostToolUse
# payload into the canonical `agent_audit.tool_call` document defined in
# SPEC/agent-audit.md, and POSTs it straight to the local Agent Audit tool-call data
# stream (direct-to-Elasticsearch, independent of the OTLP/APM pipeline). No sealing:
# content=plaintext stores the tool I/O in plaintext (a future encrypted mode nulls
# .text and uses .encrypted_text).
# (Sibling of capture-user-prompt.ps1, the UserPromptSubmit audit hook.)
#
# Delivery config is read at run time from the flat key=value agent-audit.conf (zero
# external deps — ConvertFrom-StringData, no jq/TOML parser; see SPEC/agent-audit.md
# "Delivery and authorization"). This hook reads only the tool_call stream's keys:
# capture.tool_call.enabled (false => skip), capture.tool_call.content (plaintext =>
# .text; encrypted => null, sealing TBD), plus the shared elasticsearch.url / .api_key
# / .timeout_ms and the per-stream elasticsearch.data_stream.tool_call. Config path:
#   $env:CODEX_AGENT_AUDIT_CONFIG, else ${CODEX_HOME:-$HOME/.codex}/agent-audit.conf
#
# Field mapping (Codex raw payload -> canonical document):
#   .session_id -> agent_audit.conversation_id   .turn_id -> agent_audit.turn_id
#   .model -> agent_audit.agent.model
#   .tool_name   -> agent_audit.tool_call.tool.name
#   .tool_use_id -> agent_audit.tool_call.tool.call_id (per-call id; join key to the
#                   OTLP trace_safe codex.tool_result `call_id`)
#   .tool_input  -> agent_audit.tool_call.input  (serialized to a JSON STRING into
#                   .text, .length = char count; Codex's tool_input is heterogeneous,
#                   so it is serialized to one scalar — the strict mapping must not
#                   see arbitrary nested keys)
#   .tool_response -> agent_audit.tool_call.output (same serialize-to-.text treatment)
#   agent.provider/name are constants. user.* / host.* / account.* / organization.*
#   are derived exactly as capture-user-prompt.ps1 (workstation login via whoami;
#   provider identity read LOCALLY, no network, from $CODEX_HOME/auth.json claims).
#   cwd / transcript_path / permission_mode are dropped (not part of the strict
#   audit schema; cwd is PII). No success/exit field: tool_response is opaque.
#
# CONTRACT — must never disturb the Codex session:
#   * Writes NOTHING to stdout (hook-event stdout can be injected into the model
#     context). Diagnostics go to stderr via [Console]::Error so they never reach
#     stdout.
#   * ALWAYS exits 0 (fail-open). Bad payload / missing config / unreachable
#     Elasticsearch / any error leaves the tool call unblocked; the POST uses a
#     very short timeout so an unavailable destination never delays the session.

$ErrorActionPreference = 'Stop'

function Log($m) { [Console]::Error.WriteLine("[capture-tool-call] $m") }

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
    } catch { Write-Verbose "fail-open: $_" }
    return $r
}

# Serialize a heterogeneous Codex tool field (object or string) to a JSON STRING,
# mirroring jq's `tojson`: a string becomes a quoted JSON string, an object becomes
# compact JSON. $null stays $null (the field was absent).
function ConvertTo-JsonText($value) {
    if ($null -eq $value) { return $null }
    return ($value | ConvertTo-Json -Compress -Depth 50)
}

try {
    $stream = 'tool_call'
    $configFile = if ($env:CODEX_AGENT_AUDIT_CONFIG) {
        $env:CODEX_AGENT_AUDIT_CONFIG
    } else {
        $base = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
        Join-Path $base 'agent-audit.conf'
    }

    if (-not (Test-Path -LiteralPath $configFile)) {
        Log "no delivery config at $configFile — skipping (run setup.ps1)"; exit 0
    }

    # Flat key=value config, parsed with the built-in ConvertFrom-StringData (no jq /
    # TOML parser). Comment (#) and blank lines are ignored; dotted keys carry the
    # structure. This hook reads only the tool_call stream's keys.
    $cfg = Get-Content -Raw -LiteralPath $configFile | ConvertFrom-StringData

    if ($cfg["capture.$stream.enabled"] -eq 'false') {
        Log "capture.$stream.enabled=false — skipping (stream disabled)"; exit 0
    }
    $content    = $cfg["capture.$stream.content"]
    $esUrl      = $cfg['elasticsearch.url']
    $apiKey     = $cfg['elasticsearch.api_key']
    $timeoutMs  = $cfg['elasticsearch.timeout_ms']
    $DataStream = $cfg["elasticsearch.data_stream.$stream"]

    if (-not $esUrl -or -not $DataStream) {
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

    # tool_input / tool_response are heterogeneous JSON — serialize each to a JSON
    # STRING so the strict mapping sees one scalar per side.
    $inText  = ConvertTo-JsonText $rawObj.tool_input
    $outText = ConvertTo-JsonText $rawObj.tool_response
    $inLen   = if ($null -ne $inText)  { ([string]$inText).Length }  else { 0 }
    $outLen  = if ($null -ne $outText) { ([string]$outText).Length } else { 0 }

    # content=plaintext carries .text; any other content nulls it (sealing into
    # encrypted_text is a later increment). length is the true char count regardless.
    $plain        = ($content -eq 'plaintext')
    $inTextField  = if ($plain) { $inText }  else { $null }
    $outTextField = if ($plain) { $outText } else { $null }

    # Reshape raw Codex payload -> canonical agent_audit.tool_call document.
    $record = [ordered]@{
        '@timestamp' = $ts
        event = [ordered]@{
            action  = 'tool-call'
            created = $ts
            dataset = 'agent_audit.tool_call'
            kind    = 'event'
        }
        user = [ordered]@{
            id   = $userId
            name = $userName
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
            tool_call = [ordered]@{
                tool   = [ordered]@{ name = $rawObj.tool_name; call_id = $rawObj.tool_use_id }
                input  = [ordered]@{ text = $inTextField;  encrypted_text = $null; length = $inLen }
                output = [ordered]@{ text = $outTextField; encrypted_text = $null; length = $outLen }
            }
        }
    }

    # POST to the data stream's _doc endpoint (auto op_type=create for data
    # streams). Send a UTF-8 byte body so multi-byte tool I/O is not mangled by
    # Windows PowerShell 5.1 (the fleet default).
    $json    = $record | ConvertTo-Json -Compress -Depth 50
    $bytes   = [System.Text.Encoding]::UTF8.GetBytes($json)
    # .NET's HTTP client resolves `localhost` to IPv6 (::1) first and connects
    # serially, stalling ~2s before falling back to IPv4 — which blows the short
    # timeout_ms and makes every POST to the local lab stack fail (the bash hook's
    # curl avoids this via IPv4 preference). Rewrite a bare localhost host to
    # 127.0.0.1 so delivery behaves like curl. Any other host is left untouched.
    $esBase  = ($esUrl.TrimEnd('/')) -replace '://localhost([:/]|$)', '://127.0.0.1$1'
    $esTarget = $esBase + '/' + $DataStream + '/_doc'
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($apiKey) { $headers['Authorization'] = "ApiKey $apiKey" }

    try {
        Invoke-RestMethod -Method Post -Uri $esTarget -Headers $headers `
            -Body $bytes -TimeoutSec $timeoutSec | Out-Null
        Log "indexed 1 audit document -> $esTarget"
    } catch {
        Log "POST to $esTarget failed ($_) — tool call proceeds uncaptured"
    }
}
catch {
    Log "capture failed ($_) — tool call proceeds uncaptured"
}
exit 0
