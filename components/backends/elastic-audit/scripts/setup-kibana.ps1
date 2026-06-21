$ErrorActionPreference = 'Stop'

if (-not $env:KIBANA_URL) { throw 'KIBANA_URL must be set by the stack' }

$ScriptDir = Split-Path -Parent $PSCommandPath
$BackendDir = Split-Path -Parent $ScriptDir
$KibanaScripts = Join-Path $BackendDir '../services/kibana/scripts'

& (Join-Path $KibanaScripts 'import-kibana-assets.ps1') -Sources 'agent-audit'
