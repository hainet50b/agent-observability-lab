#!/usr/bin/env pwsh
# capture-prompt.ps1 — Claude Code UserPromptSubmit audit hook (PowerShell).
#
# PowerShell mirror of capture-prompt.sh (same .sh/.ps1 pairing as the repo's
# other scripts; this is the Windows-side capture for the same hook). See that
# file's header for the full rationale. In short: fires once per submitted
# prompt, builds a {ts, agent, user_email, organization, session_id, cwd,
# hostname, prompt} document, and POSTs it straight to the `prompts-audit`
# Elasticsearch index over a path independent of the OTLP analytics pipeline.
#
# CONTRACT — must not disturb the session:
#   * Writes NOTHING to stdout (on UserPromptSubmit, exit-0 stdout is injected
#     into the model's context). Diagnostics go to stderr via Write-Error-free
#     [Console]::Error so they never reach stdout.
#   * ALWAYS exits 0 (best-effort). Elasticsearch down / network error / bad
#     payload all leave the user's prompt unblocked.
#   * Invoke-RestMethod uses a short -TimeoutSec so a stalled endpoint can't hang
#     the prompt.
#
# Override the audit endpoint with PROMPTS_AUDIT_ES_URL (default below).
# NOTE: plaintext phase — prompt stored as-is; sealing is a later phase.

$EsUrl = if ($env:PROMPTS_AUDIT_ES_URL) { $env:PROMPTS_AUDIT_ES_URL } else { 'http://localhost:9200' }
$Index = 'prompts-audit'
$ClaudeConfig = if ($env:CLAUDE_CONFIG) { $env:CLAUDE_CONFIG } else { Join-Path $HOME '.claude.json' }

function Log($msg) { [Console]::Error.WriteLine("[capture-prompt] $msg") }

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $evt = $raw | ConvertFrom-Json   # built-in parser — no external dependency

    $prompt = $evt.prompt
    if (-not $prompt) { exit 0 }   # nothing to audit

    $sessionId = $evt.session_id
    # cwd is intentionally NOT captured — it is PII (see capture-prompt.sh header).

    # Identity from the local Claude Code account (best-effort; blank if absent).
    $userEmail = ''
    $organization = ''
    if (Test-Path -LiteralPath $ClaudeConfig -PathType Leaf) {
        try {
            $cfg = Get-Content -Raw -LiteralPath $ClaudeConfig | ConvertFrom-Json
            $userEmail = [string]$cfg.oauthAccount.emailAddress
            $organization = [string]$cfg.oauthAccount.organizationName
        } catch { Write-Verbose "fail-open: $_" }
    }

    $hostname = [System.Net.Dns]::GetHostName()
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    $doc = [ordered]@{
        '@timestamp' = $ts
        agent        = 'claude-code'
        session_id   = $sessionId
        hostname     = $hostname
        prompt       = $prompt
    }
    if ($userEmail)    { $doc['user_email'] = $userEmail }
    if ($organization) { $doc['organization'] = $organization }

    # Send the body as explicit UTF-8 bytes. Windows PowerShell 5.1 (the build
    # that ships with every Windows, so the fleet default) otherwise sends a
    # JSON string body as Latin-1 and mangles non-ASCII — Japanese prompts would
    # arrive corrupted. PowerShell 7 is fine, but bytes are correct on both.
    $json  = $doc | ConvertTo-Json -Compress -Depth 5
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Invoke-RestMethod -Method Post -Uri "$EsUrl/$Index/_doc" `
        -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 5 | Out-Null
    Log "audited prompt for session $sessionId -> $EsUrl/$Index"
}
catch {
    Log "audit failed ($_) — prompt proceeds unaudited"
}

exit 0
