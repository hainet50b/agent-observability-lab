#!/usr/bin/env pwsh
# capture-user-prompt.ps1 — Codex CLI UserPromptSubmit characterization hook
# (PowerShell mirror of capture-user-prompt.sh; same .sh/.ps1 pairing as the
# repo's other scripts). See that file's header for the full rationale. In
# short: fires once per submitted prompt, appends the RAW stdin payload plus a
# best-effort extracted `prompt` to a stack-local NDJSON capture file, to
# discover the exact Codex payload keys. CHARACTERIZATION ONLY — no POST, no
# prompts-audit, no sealing.
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

    $dir = Split-Path -Parent $captureFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    $rawObj = $null
    try { $rawObj = $raw | ConvertFrom-Json } catch { Log 'payload not valid JSON — capturing raw text' }

    if ($null -ne $rawObj) {
        $record = [ordered]@{
            captured_at = $ts
            hook        = 'codex.UserPromptSubmit'
            prompt      = $rawObj.prompt
            raw         = $rawObj
        }
    } else {
        $record = [ordered]@{
            captured_at = $ts
            hook        = 'codex.UserPromptSubmit'
            prompt      = $null
            raw_text    = $raw
        }
    }

    # Append as UTF-8 WITHOUT a BOM so multi-byte prompt text is not corrupted
    # and no BOM is injected mid-file on Windows PowerShell 5.1.
    $line  = ($record | ConvertTo-Json -Compress -Depth 20) + "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
    $fs = [System.IO.File]::Open($captureFile, [System.IO.FileMode]::Append,
        [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }

    Log "captured 1 record -> $captureFile"
}
catch {
    Log "capture failed ($_) — prompt proceeds uncaptured"
}
exit 0
