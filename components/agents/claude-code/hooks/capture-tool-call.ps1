#!/usr/bin/env pwsh

. "$PSScriptRoot/lib/agent-audit.ps1"

$script:stream = 'tool_call'

Assert-ConfigArg $args
Import-DeliveryConfig
Assert-StreamEnabled
Read-HookPayload
Build-AuditDocument
Send-Document
