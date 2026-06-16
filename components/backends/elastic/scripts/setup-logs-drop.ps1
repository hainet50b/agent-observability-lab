#!/usr/bin/env pwsh
# setup-logs-drop.ps1 — drop high-volume Codex CLI streaming-delta event docs.
#
# PowerShell mirror of setup-logs-drop.sh (same pairing as ralph.sh / ralph.ps1,
# setup-trace-routing.sh / .ps1).
#
# Codex CLI emits one event document per streamed model fragment. The three
# `event_kind`s `response.output_text.delta`,
# `response.function_call_arguments.delta` and
# `response.custom_tool_call_input.delta` are content-free incremental fragments
# (the complete value lands on the terminal `.done` event; Codex's export strips
# conversation content from them entirely) and together account for ~91% of the
# event/`log_only` stream. This installs the sanctioned drop hook: a `drop`
# processor in the **`logs-apm.app@custom`** ingest pipeline, which the managed
# `logs-apm.app@default-pipeline` already calls with
# `ignore_missing_pipeline: true` — so creating the pipeline activates it.
#
# The drop is gated on `service.name == 'codex_cli_rs'` because
# `logs-apm.app@custom` is shared across every producer (claude-code, codex_cli_rs,
# smoke-test, future agents); matching on `event_kind` alone would also hit any
# other producer that happened to emit the same value. `ctx.labels?.event_kind`
# uses null-safe navigation: `event_kind` is absent on the valuable events
# (`codex.user_prompt`, `codex.tool_result`, `response.completed`, …) and
# `null == '…'` is safely false, so those documents are kept. The list is an
# explicit allowlist (not `endsWith('.delta')`): a wildcard would blindly drop
# unverified or future `.delta` kinds (refusal, reasoning-summary, …).
#
# No content is lost: per-turn token counts survive on `response.completed`, and
# latency survives in metrics (`codex.turn.ttft.duration_ms`,
# `codex.turn.e2e_duration_ms`); metrics are not dropped.
#
# Idempotent: a PUT replaces the pipeline definition, so re-running is safe.
#
# Prerequisites: PowerShell 7+ (uses Invoke-RestMethod). Override the
# Elasticsearch base URL with -EsUrl or the ES_URL env var (default below).
#
#   ./scripts/setup-logs-drop.ps1
#   ./scripts/setup-logs-drop.ps1 -EsUrl http://localhost:9200
#
# Run from anywhere — it locates its own component directory like the .sh version.

[CmdletBinding()]
param(
    [string]$EsUrl = $(if ($env:ES_URL) { $env:ES_URL } else { 'http://localhost:9200' })
)

$ErrorActionPreference = 'Stop'
$Pipeline = 'logs-apm.app@custom'

# Resolve the component root (parent of this scripts/ directory) and build the
# pipeline-body path absolutely from it, so it resolves regardless of the caller's
# cwd — without Set-Location, which runs in the caller's PowerShell session and
# would leave their shell parked here.
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$PipelineFile = Join-Path $ComponentDir 'elasticsearch/logs-drop.pipeline.json'

# The pipeline body (a drop that fires only on Codex CLI streaming-delta docs;
# other producers and events fall through unchanged) is the single source of
# truth shared with setup-logs-drop.sh.
if (-not (Test-Path -LiteralPath $PipelineFile -PathType Leaf)) {
    Write-Error "FAIL: pipeline body not found: $PipelineFile"
    exit 1
}
$Body = Get-Content -Raw -LiteralPath $PipelineFile

Write-Host "[setup] installing ingest pipeline '$Pipeline' on $EsUrl…"
try {
    $result = Invoke-RestMethod -Method Put `
        -Uri "$EsUrl/_ingest/pipeline/$([uri]::EscapeDataString($Pipeline))" `
        -ContentType 'application/json' `
        -Body $Body
}
catch {
    Write-Error "FAIL: request to Elasticsearch failed ($_)"
    exit 1
}

$result | ConvertTo-Json -Depth 10 | Write-Host

if (-not $result.acknowledged) {
    Write-Error "FAIL: pipeline PUT not acknowledged"
    exit 1
}

Write-Host "[setup] pipeline '$Pipeline' installed"
Write-Host ""
Write-Host "PASS: Codex CLI streaming-delta event docs (service.name=codex_cli_rs) are now"
Write-Host "dropped at ingest. Run a Codex turn (see ../README.md) and confirm the"
Write-Host "response.*.delta docs no longer land in logs-apm.app.codex_cli_rs-default."
