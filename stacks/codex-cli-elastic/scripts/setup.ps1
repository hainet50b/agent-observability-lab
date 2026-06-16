#!/usr/bin/env pwsh
# setup.ps1 — one-shot bootstrap for the codex-cli-elastic stack.
#
# PowerShell mirror of setup.sh. Run once after `docker compose up -d` (healthy).
# Steps: 1) trace-routing pipeline (isolates codex-cli spans into
# traces-apm-agents_codex_cli, and drops the high-volume Codex streaming spans
# receiving+handle_responses)  2) logs-drop pipeline (logs-apm.app@custom) dropping
# the three verified high-volume Codex CLI streaming-delta event docs per
# SPEC/codex-cli-telemetry.md "Volume reduction (ingest drops)"  3) provision the
# Agent Audit data stream (logs-agent_audit.user_prompt-default) + its strict index
# template per SPEC/agent-audit.md (agent-cross-cutting, backend-owned)  4) render
# .codex/config.toml ([otel] telemetry config) from the agent-owned template, so a
# Codex session launched with CODEX_HOME=<stack>/.codex emits into the stack
# without touching the user's ~/.codex (a repo-local .codex/config.toml is ignored
# for [otel]; CODEX_HOME is the supported per-project mechanism)  5) render
# .codex/agent-audit.toml (the Agent Audit hook's Elasticsearch delivery config)
# from the agent-owned template with this stack's local ES defaults (url = -EsUrl,
# security-disabled so api_key empty; see SPEC/agent-audit.md); the step-6 hook
# reads this at run time  6) register the UserPromptSubmit Agent Audit hook into
# .codex/hooks.json — at run time it reshapes each submitted prompt into the
# canonical agent_audit.user_prompt document and POSTs it (fail-open, short
# timeout) to the local Agent Audit data stream logs-agent_audit.user_prompt-default
# using the step-5 config; lab mode stores prompt text in plaintext (no sealing
# yet)  7) import the Kibana saved
# objects: the Elastic backend's cross-agent AI Agents — Traces data view, then
# the Codex CLI agent's per-agent data views (Metrics / Events / Traces) and saved
# searches. Steps 1, 2 and 3 idempotent; steps 4, 5 and 6 create-if-absent; step 7
# imports with overwrite=true. Override the ES endpoint with -EsUrl, the Kibana URL
# with the KIBANA_URL env var. Verification (smoke-test.sh) stays separate.
#
# NOT done here (deferred): prompt sealing/encryption is not built yet — the hook
# delivers prompt text in plaintext (lab mode). A dashboard, ingest filtering,
# TTFT integration, and normalized summary indices also remain deferred (the data
# views and the curated saved searches import in step 6).

[CmdletBinding()]
param(
    [string]$EsUrl
)

$ErrorActionPreference = 'Stop'
$OtlpEndpoint = 'http://localhost:8200'
$StackDir = Split-Path -Parent $PSScriptRoot
$C = Join-Path $PSScriptRoot '../../../components'

$es = @{}; if ($EsUrl) { $es['EsUrl'] = $EsUrl }
$EsUrlLocal = if ($EsUrl) { $EsUrl } else { 'http://localhost:9200' }

function Invoke-Step {
    param([string]$Label, [string]$Path, [hashtable]$StepArgs)
    Write-Host "[setup] $Label"
    $global:LASTEXITCODE = 0
    & $Path @StepArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Invoke-Step '1/7 - trace-routing ingest pipeline' (Join-Path $C 'backends/elastic/scripts/setup-trace-routing.ps1') $es
Invoke-Step '2/7 - logs-drop ingest pipeline (logs-apm.app@custom)' `
    (Join-Path $C 'backends/elastic/scripts/setup-logs-drop.ps1') $es
Invoke-Step '3/7 - Agent Audit data stream (logs-agent_audit.user_prompt-default)' `
    (Join-Path $C 'backends/elastic/scripts/setup-agent-audit.ps1') $es
Invoke-Step '4/7 - local Codex session config (.codex/config.toml, [otel] telemetry)' `
    (Join-Path $C 'agents/codex-cli/scripts/render-config.ps1') `
    @{ OtlpEndpoint = $OtlpEndpoint; TargetDir = $StackDir }
Invoke-Step '5/7 - Agent Audit delivery config (.codex/agent-audit.toml, local ES defaults)' `
    (Join-Path $C 'agents/codex-cli/scripts/render-agent-audit.ps1') `
    @{ EsUrl = $EsUrlLocal; TargetDir = $StackDir }
Invoke-Step '6/7 - UserPromptSubmit Agent Audit hook (.codex/hooks.json, ES delivery)' `
    (Join-Path $C 'agents/codex-cli/scripts/render-hooks.ps1') `
    @{ TargetDir = $StackDir }
Invoke-Step '7/7 - Kibana saved objects (1/2): backend cross-agent AI Agents - Traces view' `
    (Join-Path $C 'backends/elastic/scripts/import-kibana-objects.ps1') @{}
Invoke-Step '7/7 - Kibana saved objects (2/2): Codex agent data views + saved searches' `
    (Join-Path $C 'agents/codex-cli/scripts/import-kibana-objects.ps1') @{}

Write-Host "[setup] done - point a Codex session at this directory (see ../README.md); verify with scripts/smoke-test.sh."
