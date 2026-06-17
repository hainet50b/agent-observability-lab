#!/usr/bin/env pwsh
# setup.ps1 — one-shot bootstrap for the codex-cli-elastic stack.
#
# PowerShell mirror of setup.sh. Run once after `docker compose up -d` (healthy).
# Bootstraps this stack's OTLP telemetry path. (The DIRECT Agent Audit path — hook
# → Elasticsearch — is a SEPARATE stack, codex-cli-elastic-audit; not part of this
# telemetry stack.) Steps: 1) trace-routing pipeline (isolates codex-cli spans into
# traces-apm-agents_codex_cli, and drops the high-volume Codex streaming spans
# receiving+handle_responses)  2) logs-drop pipeline (logs-apm.app@custom) dropping
# the three verified high-volume Codex CLI streaming-delta event docs per
# SPEC/codex-cli-telemetry.md "Volume reduction (ingest drops)"  3) render
# .codex/config.toml ([otel] telemetry config + the local Elasticsearch MCP server
# via render-mcp) from the agent-owned templates, so a
# Codex session launched with CODEX_HOME=<stack>/.codex emits into the stack
# without touching the user's ~/.codex (a repo-local .codex/config.toml is ignored
# for [otel]; CODEX_HOME is the supported per-project mechanism)  4) import the
# Kibana saved objects: the Elastic backend's cross-agent AI Agents — Traces data
# view, then the Codex CLI agent's per-agent data views (Metrics / Events / Traces)
# and saved searches. Steps 1 and 2 idempotent; step 3 create-if-absent; step 4
# imports with overwrite=true. Override the ES endpoint with -EsUrl, the Kibana URL
# with the KIBANA_URL env var. Verification (smoke-test.sh) stays separate.
#
# NOT done here (deferred): a dashboard, ingest filtering, TTFT integration, and
# normalized summary indices remain deferred (the data views and the curated saved
# searches import in step 4). For prompt / tool-call audit, use the
# codex-cli-elastic-audit stack.

[CmdletBinding()]
param(
    [string]$EsUrl
)

$ErrorActionPreference = 'Stop'
$OtlpEndpoint = 'http://localhost:8200'
$StackDir = Split-Path -Parent $PSScriptRoot
$C = Join-Path $PSScriptRoot '../../../components'

$es = @{}; if ($EsUrl) { $es['EsUrl'] = $EsUrl }

function Invoke-Step {
    param([string]$Label, [string]$Path, [hashtable]$StepArgs)
    Write-Host "[setup] $Label"
    $global:LASTEXITCODE = 0
    & $Path @StepArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Invoke-Step -Label '1/4 - trace-routing ingest pipeline' -Path (Join-Path $C 'backends/elastic/scripts/setup-trace-routing.ps1') -StepArgs $es
Invoke-Step -Label '2/4 - logs-drop ingest pipeline (logs-apm.app@custom)' `
    -Path (Join-Path $C 'backends/elastic/scripts/setup-logs-drop.ps1') -StepArgs $es
Invoke-Step -Label '3/4 - Codex session config: [otel] telemetry (.codex/config.toml)' `
    -Path (Join-Path $C 'agents/codex-cli/scripts/render-otel.ps1') `
    -StepArgs @{ OtlpEndpoint = $OtlpEndpoint; TargetDir = $StackDir }
Invoke-Step -Label '3/4 - Codex session config: Elasticsearch MCP (.codex/config.toml)' `
    -Path (Join-Path $C 'agents/codex-cli/scripts/render-mcp.ps1') `
    -StepArgs @{ TargetDir = $StackDir }
Invoke-Step -Label '4/4 - Kibana saved objects (backend cross-agent view + Codex agent data views + saved searches)' `
    -Path (Join-Path $C 'backends/elastic/scripts/import-kibana-objects.ps1') -StepArgs @{ Sources = @('codex-cli') }

Write-Host "[setup] done - point a Codex session at this directory (see ../README.md); verify with scripts/smoke-test.sh."

