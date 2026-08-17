$ErrorActionPreference = 'Stop'

$env:ESPALIER_NETWORK = 'codex-elastic_default'
& (Join-Path $PSScriptRoot '../../../backends/elastic/provision.ps1')
exit $LASTEXITCODE
