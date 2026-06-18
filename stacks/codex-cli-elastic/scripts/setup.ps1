#!/usr/bin/env pwsh
# setup.ps1 — PowerShell mirror of setup.sh: one-shot post-up bootstrap for the
# codex-cli-elastic OTLP telemetry path. Run once after `docker compose up -d`
# reports healthy. Each step delegates to a component script (see README.md for
# what each does, SPEC/ for the rationale). Steps are idempotent / create-if-absent,
# so re-running is safe. Override the ES endpoint with -EsUrl and the Kibana URL
# with the KIBANA_URL env var.
#
# Verification (smoke-test.sh) and prompt/tool-call audit (the codex-cli-elastic-audit
# stack) are separate concerns, not part of this script.

[CmdletBinding()]
param(
    [string]$EsUrl
)

$ErrorActionPreference = 'Stop'
$OtlpEndpoint = 'http://localhost:8200'
$StackDir = Split-Path -Parent $PSScriptRoot
$C = Join-Path $PSScriptRoot '../../../components'

# Forward -EsUrl to the component scripts only when set, so each falls back to its own default.
$es = @{}; if ($EsUrl) { $es['EsUrl'] = $EsUrl }

# PowerShell does not abort on a child script's nonzero exit (no `set -e`), so each
# step checks $LASTEXITCODE explicitly.
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
Invoke-Step -Label '3/4 - Codex session config (.codex/config.toml: [otel])' `
    -Path (Join-Path $C 'agents/codex-cli/scripts/render-otel.ps1') `
    -StepArgs @{ OtlpEndpoint = $OtlpEndpoint; TargetDir = $StackDir }
Invoke-Step -Label '3/4 - Codex session config (.codex/config.toml: Elasticsearch MCP)' `
    -Path (Join-Path $C 'agents/codex-cli/scripts/render-mcp.ps1') `
    -StepArgs @{ TargetDir = $StackDir }
Invoke-Step -Label '4/4 - Kibana saved objects (data views + saved searches)' `
    -Path (Join-Path $C 'backends/elastic/scripts/import-kibana-objects.ps1') -StepArgs @{ Sources = @('codex-cli') }

Write-Host "[setup] done - point a Codex session at this directory (see ../README.md); verify with scripts/smoke-test.sh."

