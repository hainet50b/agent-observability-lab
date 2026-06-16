#!/usr/bin/env pwsh
# capture-tool-call.ps1 — Codex CLI PostToolUse characterization hook
# (PowerShell mirror of capture-tool-call.sh; same .sh/.ps1 pairing as the
# repo's other scripts). See that file's header for the full rationale. In
# short: fires once per completed tool call, appends the RAW stdin payload plus
# best-effort extracted `tool_name` / `tool_use_id` / `tool_input` /
# `tool_response` to a stack-local NDJSON capture file, to discover the exact
# Codex PostToolUse payload keys. CHARACTERIZATION ONLY — no POST, no audit
# stream, no sealing.
#
# CONTRACT — must never disturb the Codex session:
#   * Writes NOTHING to stdout (hook-event stdout can be injected into the model
#     context). Diagnostics go to stderr via [Console]::Error so they never
#     reach stdout.
#   * ALWAYS exits 0 (best-effort). Bad payload / unwritable path / any error
#     leaves the tool call unblocked.
#
# Capture file: $env:CODEX_HOOK_CAPTURE_FILE, else
#   ${CODEX_HOME:-$HOME/.codex}/hook-captures/tool-call.ndjson

$ErrorActionPreference = 'Stop'

function Log($m) { [Console]::Error.WriteLine("[capture-tool-call] $m") }

try {
    $captureFile = if ($env:CODEX_HOOK_CAPTURE_FILE) {
        $env:CODEX_HOOK_CAPTURE_FILE
    } else {
        $base = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
        Join-Path $base 'hook-captures/tool-call.ndjson'
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
            captured_at   = $ts
            hook          = 'codex.PostToolUse'
            tool_name     = $rawObj.tool_name
            tool_use_id   = $rawObj.tool_use_id
            tool_input    = $rawObj.tool_input
            tool_response = $rawObj.tool_response
            raw           = $rawObj
        }
    } else {
        $record = [ordered]@{
            captured_at   = $ts
            hook          = 'codex.PostToolUse'
            tool_name     = $null
            tool_use_id   = $null
            tool_input    = $null
            tool_response = $null
            raw_text      = $raw
        }
    }

    # Append as UTF-8 WITHOUT a BOM so multi-byte tool I/O is not corrupted and
    # no BOM is injected mid-file on Windows PowerShell 5.1.
    $line  = ($record | ConvertTo-Json -Compress -Depth 20) + "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
    $fs = [System.IO.File]::Open($captureFile, [System.IO.FileMode]::Append,
        [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }

    Log "captured 1 record -> $captureFile"
}
catch {
    Log "capture failed ($_) — tool call proceeds uncaptured"
}
exit 0
