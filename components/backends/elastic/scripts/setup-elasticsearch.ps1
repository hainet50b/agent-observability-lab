#!/usr/bin/env pwsh
# setup-elasticsearch.ps1 — apply the Elastic backend's Elasticsearch-side assets
# (PowerShell mirror of setup-elasticsearch.sh).
#
# Composition only: this backend owns no asset files. It selects the concern
# intrinsic to the `elastic` (full OTLP telemetry) backend — `shared` (the
# agent-agnostic @custom ingest routers) — plus the agent concern(s) the stack
# composes (-Sources), and applies them through the elasticsearch service's concern
# importer. Only the composed agent's sub-pipelines are installed; the routers
# dispatch by service.name. Rationale lives at each asset's single source (JSON
# body / SPEC), not here.

[CmdletBinding()]
param(
    [string]$EsUrl = $(if ($env:ES_URL) { $env:ES_URL } else { 'http://localhost:9200' }),
    [Parameter(Mandatory = $true)]
    [string[]]$Sources
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$EsScripts = Join-Path $ComponentDir '../services/elasticsearch/scripts'

& (Join-Path $EsScripts 'import-elasticsearch-assets.ps1') -EsUrl $EsUrl -Concerns (@('shared') + $Sources)
