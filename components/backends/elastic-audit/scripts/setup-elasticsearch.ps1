#!/usr/bin/env pwsh
# setup-elasticsearch.ps1 — apply the Elastic-audit backend's Elasticsearch assets
# (PowerShell mirror of setup-elasticsearch.sh).
#
# Composition only: this backend owns no asset files. It selects the assets
# intrinsic to the `elastic-audit` backend's identity — the two Agent Audit
# data-stream templates (logs-agent_audit.user_prompt / .tool_call) — and applies
# them through the elasticsearch service's generic index-template applier (install
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

& (Join-Path $EsScripts 'import-index-templates.ps1') -EsUrl $EsUrl -Names 'logs-agent_audit.user_prompt', 'logs-agent_audit.tool_call'

