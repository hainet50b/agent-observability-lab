$ErrorActionPreference = 'Stop'

$env:ESPALIER_NETWORK = 'claude-elastic-audit_default'
& (Join-Path $PSScriptRoot '../../../backends/elastic/provision.ps1')
exit $LASTEXITCODE
