#!/usr/bin/env pwsh
# import-kibana-objects.ps1 — stack import orchestrator.
#
# PowerShell mirror of import-kibana-objects.sh. This stack composes the Elastic
# backend with the Claude Code agent over the otelcol-sidecar path, so a full
# Kibana import is three component imports run in order:
#   1. components/backends/elastic/scripts/import-kibana-objects.ps1
#      — the cross-agent backend data view (AI Agents — Traces)
#   2. components/agents/claude-code/scripts/import-kibana-objects.ps1
#      — the per-agent data views, saved searches, and Overview dashboard
#   3. components/paths/otelcol-sidecar/scripts/import-kibana-objects.ps1
#      — the sidecar self-telemetry data view (OTel Collector Sidecar — Metrics)
# Keeping the script name preserves the command the user is accustomed to.
# -KibanaUrl forwards to every sub-script. Each sub-script (and this one) runs
# with $ErrorActionPreference = 'Stop', so a sub-script failure raises a
# terminating error that propagates here and aborts before the next import —
# fail-fast, with each import only running if the previous one succeeded.

[CmdletBinding()]
param(
    [string]$KibanaUrl
)

$ErrorActionPreference = 'Stop'

$Components = Join-Path $PSScriptRoot '../../../components'

& (Join-Path $Components 'backends/elastic/scripts/import-kibana-objects.ps1') @PSBoundParameters
& (Join-Path $Components 'agents/claude-code/scripts/import-kibana-objects.ps1') @PSBoundParameters
& (Join-Path $Components 'paths/otelcol-sidecar/scripts/import-kibana-objects.ps1') @PSBoundParameters

exit 0
