#!/usr/bin/env pwsh
# setup-kibana.ps1 — import the Elastic-audit backend's Kibana saved objects
# (PowerShell mirror of setup-kibana.sh).
#
# Composition only: this backend owns no asset files. The Agent Audit views are
# intrinsic to this backend's identity — cross-agent (the AI agent is a document
# field, not a stream-name segment), so every audit stack wants exactly them. The
# source is fixed here (agent-audit) and applied through the kibana service's
# generic importer. The stack calls this backend script rather than reaching into
# services/, keeping the component layering intact.

[CmdletBinding()]
param(
    [string]$KibanaUrl = $(if ($env:KIBANA_URL) { $env:KIBANA_URL } else { 'http://localhost:5601' })
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$KibanaScripts = Join-Path $ComponentDir '../services/kibana/scripts'

& (Join-Path $KibanaScripts 'import-kibana-assets.ps1') -KibanaUrl $KibanaUrl -Sources 'agent-audit'
