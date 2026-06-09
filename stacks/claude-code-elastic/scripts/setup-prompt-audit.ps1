#!/usr/bin/env pwsh
# setup-prompt-audit.ps1 — stack shim.
#
# The real implementation lives in the Elastic backend component:
#   ../../components/backends/elastic/scripts/setup-prompt-audit.ps1
# This forwarder keeps the command the user is accustomed to
# (`scripts/setup-prompt-audit.ps1` from the stack dir) working. It mirrors the
# real script's parameter signature so -EsUrl forwards through, then exits with
# the real script's exit code.

[CmdletBinding()]
param(
    [string]$EsUrl
)

$Real = Join-Path $PSScriptRoot '../../../components/backends/elastic/scripts/setup-prompt-audit.ps1'
& $Real @PSBoundParameters
exit $LASTEXITCODE
