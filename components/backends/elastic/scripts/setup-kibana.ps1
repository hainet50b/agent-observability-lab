#!/usr/bin/env pwsh
# setup-kibana.ps1 — import the Elastic backend's Kibana saved objects
# (PowerShell mirror of setup-kibana.sh).
#
# Composition only: this backend owns no asset files. The telemetry backend's
# Kibana views are per-agent, so the source selection is the stack's — it passes
# the source namespace(s) for the agent(s) it composes via -Sources, which this
# script forwards to the kibana service's generic importer. Routing through the
# backend (rather than the stack reaching into services/) keeps the component
# layering intact.

[CmdletBinding()]
param(
    [string]$KibanaUrl = $(if ($env:KIBANA_URL) { $env:KIBANA_URL } else { 'http://localhost:5601' }),
    [Parameter(Mandatory = $true)]
    [string[]]$Sources
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$KibanaScripts = Join-Path $ComponentDir '../services/kibana/scripts'

& (Join-Path $KibanaScripts 'import-kibana-objects.ps1') -KibanaUrl $KibanaUrl -Sources $Sources
