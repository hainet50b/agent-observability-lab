$ErrorActionPreference = 'Stop'

$env:ESPALIER_NETWORK = 'codex-elastic-audit_default'
& (Join-Path $PSScriptRoot '../../../backends/elastic/provision.ps1')
exit $LASTEXITCODE
