#!/usr/bin/env pwsh
# import-kibana-objects.ps1 — stack shim.
#
# The real implementation lives in the Elastic backend component:
#   ../../components/backends/elastic/scripts/import-kibana-objects.ps1
# This forwarder keeps the command the user is accustomed to
# (`scripts/import-kibana-objects.ps1` from the stack dir) working. It mirrors the
# real script's parameter signature so -KibanaUrl forwards through, then exits
# with the real script's exit code.

[CmdletBinding()]
param(
    [string]$KibanaUrl
)

$Real = Join-Path $PSScriptRoot '../../../components/backends/elastic/scripts/import-kibana-objects.ps1'
& $Real @PSBoundParameters
exit $LASTEXITCODE
