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
# .codex/config.toml ([otel] telemetry config) from the agent-owned template, so a
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

Invoke-Step '1/4 - trace-routing ingest pipeline' (Join-Path $C 'backends/elastic/scripts/setup-trace-routing.ps1') $es
Invoke-Step '2/4 - logs-drop ingest pipeline (logs-apm.app@custom)' `
    (Join-Path $C 'backends/elastic/scripts/setup-logs-drop.ps1') $es
Invoke-Step '3/4 - local Codex session config (.codex/config.toml, [otel] telemetry)' `
    (Join-Path $C 'agents/codex-cli/scripts/render-config.ps1') `
    @{ OtlpEndpoint = $OtlpEndpoint; TargetDir = $StackDir }
Invoke-Step '4/4 - Kibana saved objects (1/2): backend cross-agent AI Agents - Traces view' `
    (Join-Path $C 'backends/elastic/scripts/import-kibana-objects.ps1') @{}
Invoke-Step '4/4 - Kibana saved objects (2/2): Codex agent data views + saved searches' `
    (Join-Path $C 'agents/codex-cli/scripts/import-kibana-objects.ps1') @{}

Write-Host "[setup] done - point a Codex session at this directory (see ../README.md); verify with scripts/smoke-test.sh."
