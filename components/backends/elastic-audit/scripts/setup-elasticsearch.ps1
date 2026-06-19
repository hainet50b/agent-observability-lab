#!/usr/bin/env pwsh
# setup-elasticsearch.ps1 — apply the Elastic-audit backend's Elasticsearch assets
# (PowerShell mirror of setup-elasticsearch.sh).
#
# Composition only: this backend owns no asset files. The Agent Audit data-stream
# templates are intrinsic to this backend, so the `agent-audit` concern is fixed
# here and applied through the elasticsearch service's concern importer (install
# template, create <name>-default data stream, sync strict mapping). Rationale
# lives at its single source (the template JSON / SPEC/agent-audit.md), not here.

[CmdletBinding()]
param(
    [string]$EsUrl = $(if ($env:ES_URL) { $env:ES_URL } else { 'http://localhost:9200' })
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$EsScripts = Join-Path $ComponentDir '../services/elasticsearch/scripts'

& (Join-Path $EsScripts 'import-elasticsearch-assets.ps1') -EsUrl $EsUrl -Concerns 'agent-audit'
