#!/usr/bin/env pwsh
# Runs under Windows PowerShell 5.1 (powershell.exe) on the employee fleet — no
# PS7-only syntax. On Windows it is spawned by powershell.exe via the exec-form
# hook (see render-hook.ps1); the pwsh shebang is only for direct execution on
# POSIX (where powershell.exe does not exist) and implies no PS7 runtime requirement.
#
# capture-tool-call.ps1 — Claude Code PostToolUse audit hook
# (PowerShell mirror of capture-tool-call.sh; same .sh/.ps1 pairing as the repo's
# other scripts). See that file's header for the full rationale. In short: fires
# once per completed tool call, reshapes Claude's raw PostToolUse payload into the
# canonical `agent_audit.tool_call` document defined in SPEC/agent-audit.md, and
# POSTs it straight to the local Agent Audit tool-call data stream
# (direct-to-Elasticsearch, independent of the OTLP/APM pipeline). No sealing:
# content=plaintext stores the tool I/O in plaintext (a future encrypted mode nulls
# .text and uses .encrypted_text).
# (Sibling of capture-user-prompt.ps1, the UserPromptSubmit audit hook.)
#
# Delivery config is read at run time from the flat key=value agent-audit.conf (zero
# external deps — ConvertFrom-StringData, no external JSON CLI / TOML parser; see
# SPEC/agent-audit.md "Delivery and authorization"). This hook reads only the
# tool_call stream's keys: capture.tool_call.enabled (false => skip),
# capture.tool_call.content (plaintext => .text; redacted => [REDACTED] marker;
# encrypted => null, sealing TBD), plus the shared elasticsearch.url / .api_key /
# .timeout_ms and the per-stream elasticsearch.data_stream.tool_call. Config path:
#   INJECTED via -Config / --config <abs path> from the rendered hook command (no ambient discovery).
#
# Field mapping (Claude raw payload -> canonical document):
#   .session_id -> agent_audit.conversation_id   .turn_id -> agent_audit.turn_id
#   .tool_name   -> agent_audit.tool_call.tool.name
#   .tool_use_id -> agent_audit.tool_call.tool.call_id (per-call id; join key to the
#                   OTLP tool-result span's call_id)
#   .tool_input  -> agent_audit.tool_call.input  (serialized to a JSON STRING into
#                   .text, .length = char count; Claude's tool_input is heterogeneous,
#                   so it is serialized to one scalar — the strict mapping must not
#                   see arbitrary nested keys)
#   .tool_response -> agent_audit.tool_call.output (same serialize-to-.text treatment)
#   agent.provider/name are constants ("anthropic"/"claude-code"). user.* / host.* /
#   account.* / organization.* are derived exactly as capture-user-prompt.ps1
#   (workstation login via whoami; provider identity read LOCALLY, no network, from
#   ~/.claude.json's oauthAccount object — plain JSON, no JWT to decode).
#   cwd / transcript_path / permission_mode are dropped (not part of the strict
#   audit schema; cwd is PII). No success/exit field: tool_response is opaque.
#
# CONTRACT — must never disturb the Claude session:
#   * Writes NOTHING to stdout (hook-event stdout can be injected into the model
#     context). Diagnostics go to stderr via [Console]::Error so they never reach
#     stdout.
#   * ALWAYS exits 0 (fail-open). Bad payload / missing config / unreachable
#     Elasticsearch / any error leaves the tool call unblocked; the POST uses a
#     very short timeout so an unavailable destination never delays the session.

$ErrorActionPreference = 'Stop'

function Log($m) { [Console]::Error.WriteLine("[capture-tool-call] $m") }

# Coerce an empty/whitespace value to $null so the JSON carries null, not "".
function NullIfEmpty($v) { if ([string]::IsNullOrWhiteSpace([string]$v)) { return $null } return [string]$v }

# Serialize a heterogeneous Claude tool field (object or string) to a JSON STRING,
# mirroring jq's `tojson`: a string becomes a quoted JSON string, an object becomes
# compact JSON. $null stays $null (the field was absent).
function ConvertTo-JsonText($value) {
    if ($null -eq $value) { return $null }
    return ($value | ConvertTo-Json -Compress -Depth 50)
}

try {
    $stream = 'tool_call'

    # Config path is INJECTED via -Config / --config (the rendered hook command in
    # settings.local.json supplies the absolute agent-audit.conf path). A shipped hook
    # does NOT infer its config from cwd / $HOME — explicit injection only.
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
    # external JSON CLI / TOML parser). Comment (#) and blank lines are ignored; dotted
    # keys carry the structure. This hook reads only the tool_call stream's keys.
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

    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    # Best-effort runtime identity (Claude's payload has none).
    $userName = if ($env:USER) { $env:USER } elseif ($env:USERNAME) { $env:USERNAME } else { [Environment]::UserName }
    $userName = NullIfEmpty $userName
    # user.id is the domain-qualified workstation login (whoami: DOMAIN\user on
    # Windows, bare login on POSIX). Empty -> null.
    $userId = try { ([string](& whoami) 2>$null).Trim() } catch { $null }
    $userId = NullIfEmpty $userId

    # Best-effort runtime host (ECS host.hostname/host.name). name == hostname here.
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

    # tool_input / tool_response are heterogeneous JSON — serialize each to a JSON
    # STRING so the strict mapping sees one scalar per side.
    $inText = ConvertTo-JsonText $rawObj.tool_input
    $outText = ConvertTo-JsonText $rawObj.tool_response
    $inLen = if ($null -ne $inText) { ([string]$inText).Length } else { 0 }
    $outLen = if ($null -ne $outText) { ([string]$outText).Length } else { 0 }

    # Body form by capture.tool_call.content: plaintext carries the real serialized
    # tool I/O; redacted carries a fixed [REDACTED] marker in each present side
    # (verifies the delivery path without exposing tool content); encrypted (or
    # anything else) nulls them (sealing into encrypted_text is a later increment).
    # length is the true char count regardless.
    $inTextField = if ($content -eq 'plaintext') { $inText }
    elseif ($content -eq 'redacted' -and $null -ne $inText) { '[REDACTED]' }
    else { $null }
    $outTextField = if ($content -eq 'plaintext') { $outText }
    elseif ($content -eq 'redacted' -and $null -ne $outText) { '[REDACTED]' }
    else { $null }

    # Reshape raw Claude payload -> canonical agent_audit.tool_call document.
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
                provider     = 'anthropic'
                name         = 'claude-code'
                account      = [ordered]@{ id = $acctId; name = $acctName; email = $acctEmail }
                organization = [ordered]@{ id = $orgId; name = $orgName }
            }
            conversation_id = (NullIfEmpty $rawObj.session_id)
            turn_id         = (NullIfEmpty $rawObj.turn_id)
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
    $json = $record | ConvertTo-Json -Compress -Depth 50
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
        Log "POST to $esTarget failed ($_) — tool call proceeds uncaptured"
    }
}
catch {
    Log "capture failed ($_) — tool call proceeds uncaptured"
}
exit 0

