#!/usr/bin/env pwsh
# setup-elasticsearch.ps1 — apply the Elastic backend's Elasticsearch-side assets
# (PowerShell mirror of setup-elasticsearch.sh).
#
# Composition only: this backend owns no asset files. It selects the assets
# intrinsic to the `elastic` (full OTLP telemetry) backend's identity and applies
# them through the elasticsearch service's generic appliers (the ingest pipelines
# traces-apm@custom + logs-apm.app@custom, and the prompts-audit index). Each
# asset's rationale lives at its single source (the JSON body / SPEC), not here.

[CmdletBinding()]
param(
    [string]$EsUrl = $(if ($env:ES_URL) { $env:ES_URL } else { 'http://localhost:9200' })
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$EsScripts = Join-Path $ComponentDir '../services/elasticsearch/scripts'

& (Join-Path $EsScripts 'import-ingest-pipelines.ps1') -EsUrl $EsUrl -Names 'traces-apm@custom', 'logs-apm.app@custom'
& (Join-Path $EsScripts 'import-indices.ps1') -EsUrl $EsUrl -Names 'prompts-audit'

