param(
    [string]$Stream,
    [string]$Config
)

$core = Join-Path $PSScriptRoot 'lib/agent-audit-core.ps1'
if (-not (Test-Path -LiteralPath $core)) { $core = Join-Path $PSScriptRoot '../../shared/agent-audit/lib/agent-audit-core.ps1' }
. $core
. "$PSScriptRoot/lib/adapter.ps1"

$script:Stream = $Stream
Assert-Stream $Stream
Assert-Config $Config
Import-DeliveryConfig $Stream
Assert-StreamEnabled $Stream
Read-HookPayload $Stream
Build-AuditDocument $Stream
Send-Document


