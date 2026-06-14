#!/usr/bin/env pwsh
# capture-user-prompt.ps1 — Codex CLI UserPromptSubmit audit hook
# (PowerShell mirror of capture-user-prompt.sh; same .sh/.ps1 pairing as the
# repo's other scripts). See that file's header for the full rationale. In
# short: fires once per submitted prompt, reshapes Codex's raw hook payload into
# the canonical `agent_audit.user_prompt` document defined in SPEC/agent-audit.md,
# and appends it (one per line) to a stack-local NDJSON capture file. This is the
# exact shape that lands in `logs-agent_audit.user_prompt-default`; for now it
# ONLY writes the local file — no POST, no sealing (plaintext prompt, lab mode).
#
# Field mapping (Codex raw payload -> canonical document):
#   .session_id -> agent_audit.conversation_id   .turn_id -> agent_audit.turn_id
#   .model -> agent_audit.agent.model            .prompt  -> agent_audit.prompt.text
#   agent.provider/name are constants; prompt.length is the prompt's char count.
#   user.* is best-effort (only the runtime OS username is available as user.name;
#   id/email stay null). cwd / transcript_path / permission_mode are dropped (not
#   part of the strict audit schema; cwd is PII).
#
# CONTRACT — must never disturb the Codex session:
#   * Writes NOTHING to stdout (on UserPromptSubmit, exit-0 stdout can be
#     injected into the model context). Diagnostics go to stderr via
#     [Console]::Error so they never reach stdout.
#   * ALWAYS exits 0 (best-effort). Bad payload / unwritable path / any error
#     leaves the user's prompt unblocked.
#
# Capture file: $env:CODEX_HOOK_CAPTURE_FILE, else
#   ${CODEX_HOME:-$HOME/.codex}/hook-captures/user-prompt-submit.ndjson

$ErrorActionPreference = 'Stop'

function Log($m) { [Console]::Error.WriteLine("[capture-user-prompt] $m") }

try {
    $captureFile = if ($env:CODEX_HOOK_CAPTURE_FILE) {
        $env:CODEX_HOOK_CAPTURE_FILE
    } else {
        $base = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
        Join-Path $base 'hook-captures/user-prompt-submit.ndjson'
    }

    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { Log 'empty stdin — nothing to capture'; exit 0 }

    $rawObj = $null
    try { $rawObj = $raw | ConvertFrom-Json } catch {
        Log 'payload not valid JSON — cannot shape audit document; skipping'; exit 0
    }

    $dir = Split-Path -Parent $captureFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    # Best-effort runtime identity (Codex's payload has none).
    $userName = if ($env:USER) { $env:USER } elseif ($env:USERNAME) { $env:USERNAME } else { [Environment]::UserName }
    if (-not $userName) { $userName = $null }

    $promptText = $rawObj.prompt
    $promptLen  = if ($null -ne $promptText) { ([string]$promptText).Length } else { 0 }

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
            id    = $null
            name  = $userName
            email = $null
        }
        agent_audit = [ordered]@{
            agent = [ordered]@{
                provider = 'openai'
                name     = 'codex-cli'
                model    = $rawObj.model
            }
            conversation_id = $rawObj.session_id
            turn_id         = $rawObj.turn_id
            prompt = [ordered]@{
                text           = $promptText
                encrypted_text = $null
                length         = $promptLen
            }
        }
    }

    # Append as UTF-8 WITHOUT a BOM so multi-byte prompt text is not corrupted
    # and no BOM is injected mid-file on Windows PowerShell 5.1.
    $line  = ($record | ConvertTo-Json -Compress -Depth 20) + "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
    $fs = [System.IO.File]::Open($captureFile, [System.IO.FileMode]::Append,
        [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }

    Log "captured 1 audit document -> $captureFile"
}
catch {
    Log "capture failed ($_) — prompt proceeds uncaptured"
}
exit 0
