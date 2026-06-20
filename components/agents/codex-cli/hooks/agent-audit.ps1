param(
    [string]$Stream,
    [string]$Config
)

. "$PSScriptRoot/../../shared/agent-audit/lib/agent-audit-core.ps1"
. "$PSScriptRoot/lib/adapter.ps1"

$script:Stream = $Stream
Assert-Stream $Stream
Assert-Config $Config
Import-DeliveryConfig $Stream
Assert-StreamEnabled $Stream
Read-HookPayload $Stream
Build-AuditDocument $Stream
Send-Document
