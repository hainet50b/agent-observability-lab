[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Sources
)

$ErrorActionPreference = 'Stop'

if (-not $env:ES_URL) { throw 'ES_URL must be set by the stack' }

$ScriptDir = Split-Path -Parent $PSCommandPath
$BackendDir = Split-Path -Parent $ScriptDir
$EsScripts = Join-Path $BackendDir '../services/elasticsearch/scripts'

& (Join-Path $EsScripts 'import-elasticsearch-assets.ps1') -Concerns (@('shared') + $Sources)
