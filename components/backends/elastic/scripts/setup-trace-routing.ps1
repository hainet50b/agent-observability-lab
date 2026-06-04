#!/usr/bin/env pwsh
# setup-trace-routing.ps1 — physically isolate Claude Code's trace spans.
#
# PowerShell mirror of setup-trace-routing.sh (same pairing as ralph.sh /
# ralph.ps1, import-kibana-objects.sh / .ps1).
#
# APM Server writes every OTLP span to the service-agnostic `traces-apm-default`
# data stream (unlike the metrics/events streams, whose dataset embeds the
# service), so spans from all producers co-mingle and a data view can't store a
# `service.name` filter to separate them. This installs the sanctioned routing
# hook: a `reroute` processor in the **`traces-apm@custom`** ingest pipeline,
# which `traces-apm@default-pipeline` already calls with
# `ignore_missing_pipeline: true`. Docs whose `service.name` is `claude-code`
# are rerouted into the dedicated **`traces-apm-agents_claude_code`** data stream
# — it still matches the `traces-apm-*` index template, so it inherits the full
# APM trace mappings; other producers stay in `traces-apm-default`. Rerouting to
# the same namespace is a no-op, so there is no pipeline loop.
#
# The per-agent namespace (`agents_claude_code`, not a bare `claude_code`) gives
# each agent its own droppable stream and a cross-agent glob `traces-apm-agents_*`
# that still excludes non-agent traces. Agent trace spans can carry PII (prompt /
# tool I/O / code) and are experimental and high-churn, so they are isolated from
# any co-tenant production traces with independent deletion / ILM / RBAC.
#
# The traces data view (components/agents/claude-code/kibana/data-views.ndjson,
# id `claude-code-traces`) is scoped to `traces-apm-agents_claude_code*`, so it
# needs no `service.name` filter once this pipeline is installed. Spans captured
# before the pipeline existed stay in `traces-apm-default`; that is expected.
#
# Idempotent: a PUT replaces the pipeline definition, so re-running is safe.
#
# Prerequisites: PowerShell 7+ (uses Invoke-RestMethod). Override the
# Elasticsearch base URL with -EsUrl or the ES_URL env var (default below).
#
#   ./scripts/setup-trace-routing.ps1
#   ./scripts/setup-trace-routing.ps1 -EsUrl http://localhost:9200
#
# Run from anywhere — it locates its own component directory like the .sh version.

[CmdletBinding()]
param(
    [string]$EsUrl = $(if ($env:ES_URL) { $env:ES_URL } else { 'http://localhost:9200' })
)

$ErrorActionPreference = 'Stop'
$Pipeline = 'traces-apm@custom'

# Resolve the component root (parent of this scripts/ directory) and build the
# pipeline-body path absolutely from it, so it resolves regardless of the caller's
# cwd — without Set-Location, which runs in the caller's PowerShell session and
# would leave their shell parked here.
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$PipelineFile = Join-Path $ComponentDir 'elasticsearch/trace-routing.pipeline.json'

# The pipeline body (a reroute that fires only on Claude Code spans; other
# producers fall through unchanged and stay in traces-apm-default) is the single
# source of truth shared with setup-trace-routing.sh.
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
Write-Host "PASS: Claude Code trace spans (service.name=claude-code) now route to"
Write-Host "'traces-apm-agents_claude_code'. Enable tracing on a session (see ../README.md,"
Write-Host "Quick Tour step 2) and open the Claude Code — Traces data view in Discover."
