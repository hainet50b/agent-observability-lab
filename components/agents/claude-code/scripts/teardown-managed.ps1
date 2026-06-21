[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/../../shared/managed-config/lib/managed-config-core.ps1"
. "$PSScriptRoot/lib/managed-config-adapter.ps1"

Invoke-McTeardown


