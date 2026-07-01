[CmdletBinding()]
param(
    [string]$Scope = 'local',
    [string]$Target,
    [switch]$Teardown,
    [string]$Config
)

$ErrorActionPreference = 'Stop'

$StackDir = Split-Path -Parent $PSScriptRoot
$ComponentsDir = Join-Path $PSScriptRoot '../../../components'

if (-not $Config) {
    $Config = Join-Path $StackDir 'setup.conf'
}
if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) {
    [Console]::Error.WriteLine("FAIL: config file not found: $Config")
    exit 2
}

$Conf = @{}
foreach ($line in Get-Content -LiteralPath $Config) {
    if ($line -match '^\s*#' -or $line -notmatch '=') {
        continue
    }
    $k, $v = $line -split '=', 2
    $Conf[$k.Trim()] = $v.Trim()
}

$Required = @(
    'agent_audit.elasticsearch.url',
    'agent_audit.elasticsearch.timeout_ms',
    'agent_audit.capture.user_prompt.enabled',
    'agent_audit.capture.user_prompt.content',
    'agent_audit.capture.tool_call.enabled',
    'agent_audit.capture.tool_call.content'
)
foreach ($key in $Required) {
    if (-not $Conf[$key]) {
        [Console]::Error.WriteLine("FAIL: ${Config}: missing or empty key '$key'.")
        exit 2
    }
}

# Optional secret overlay (gitignored): agent_audit.elasticsearch.api_key.
# Absent file or key -> empty, no error.
$ApiKey = ''
$LocalConfig = Join-Path $StackDir 'setup.local.conf'
if (Test-Path -LiteralPath $LocalConfig -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $LocalConfig) {
        if ($line -match '^\s*#' -or $line -notmatch '=') {
            continue
        }
        $k, $v = $line -split '=', 2
        if ($k.Trim() -eq 'agent_audit.elasticsearch.api_key') {
            $ApiKey = $v.Trim()
        }
    }
}

$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $ComponentsDir 'agents/shared/agent-audit/lib/seal-resolve.ps1')
$SealResolved = Resolve-SealRecipient -RecipientsRoot (Join-Path $RepoRoot 'sealing/recipients') `
    -Epoch $Conf['agent_audit.seal.epoch'] -Override $Conf['agent_audit.seal.recipients_file'] `
    -UpContent $Conf['agent_audit.capture.user_prompt.content'] `
    -TcContent $Conf['agent_audit.capture.tool_call.content']
$SealSrc = $SealResolved[0]
$SealKeyId = $SealResolved[1]
if ($SealSrc) { $SealSrc = (Resolve-Path -LiteralPath $SealSrc).Path }

switch ($Scope) {
    'local' {
        if ($Target) {
            [Console]::Error.WriteLine('FAIL: -Scope local does not take -Target (use -Scope project to deploy into a directory)')
            exit 2
        }
        $Target = $StackDir
        if ($Teardown) {
            & (Join-Path $ComponentsDir 'agents/claude/scripts/teardown-local.ps1') -TargetDir $Target -Endpoint $Conf['agent_audit.elasticsearch.url']
        }
        else {
            & (Join-Path $ComponentsDir 'agents/claude/scripts/setup-audit.ps1') `
                -TargetDir $Target -EsUrl $Conf['agent_audit.elasticsearch.url'] `
                -ApiKey $ApiKey -TimeoutMs $Conf['agent_audit.elasticsearch.timeout_ms'] `
                -UserPromptEnabled $Conf['agent_audit.capture.user_prompt.enabled'] `
                -UserPromptContent $Conf['agent_audit.capture.user_prompt.content'] `
                -ToolCallEnabled $Conf['agent_audit.capture.tool_call.enabled'] `
                -ToolCallContent $Conf['agent_audit.capture.tool_call.content'] `
                -SealRecipientsSrc $SealSrc -SealKeyId $SealKeyId
            & (Join-Path $ComponentsDir 'agents/claude/scripts/render-mcp.ps1') -TargetDir $Target -Endpoint $Conf['agent_audit.elasticsearch.url']
        }
    }
    'project' {
        if (-not $Target) {
            [Console]::Error.WriteLine('FAIL: -Scope project requires -Target <dir>')
            exit 2
        }
        if ($Teardown) {
            & (Join-Path $ComponentsDir 'agents/claude/scripts/teardown-local.ps1') -TargetDir $Target -Endpoint $Conf['agent_audit.elasticsearch.url']
        }
        else {
            & (Join-Path $ComponentsDir 'agents/claude/scripts/setup-audit.ps1') `
                -TargetDir $Target -EsUrl $Conf['agent_audit.elasticsearch.url'] `
                -ApiKey $ApiKey -TimeoutMs $Conf['agent_audit.elasticsearch.timeout_ms'] `
                -UserPromptEnabled $Conf['agent_audit.capture.user_prompt.enabled'] `
                -UserPromptContent $Conf['agent_audit.capture.user_prompt.content'] `
                -ToolCallEnabled $Conf['agent_audit.capture.tool_call.enabled'] `
                -ToolCallContent $Conf['agent_audit.capture.tool_call.content'] `
                -SealRecipientsSrc $SealSrc -SealKeyId $SealKeyId
        }
    }
    'managed' {
        # Audit-only managed deploy: hooks, no telemetry. The audit ES url keys the
        # marker/ownership in place of an OTLP logs endpoint.
        if ($Teardown) {
            & (Join-Path $ComponentsDir 'agents/claude/scripts/teardown-managed.ps1') -WithHooks
        }
        else {
            & (Join-Path $ComponentsDir 'agents/claude/scripts/setup-managed.ps1') `
                -WithHooks -EsUrl $Conf['agent_audit.elasticsearch.url'] -EsApiKey $ApiKey `
                -TimeoutMs $Conf['agent_audit.elasticsearch.timeout_ms'] `
                -UserPromptEnabled $Conf['agent_audit.capture.user_prompt.enabled'] `
                -UserPromptContent $Conf['agent_audit.capture.user_prompt.content'] `
                -ToolCallEnabled $Conf['agent_audit.capture.tool_call.enabled'] `
                -ToolCallContent $Conf['agent_audit.capture.tool_call.content'] `
                -SealRecipientsSrc $SealSrc -SealKeyId $SealKeyId
        }
    }
    default {
        [Console]::Error.WriteLine("FAIL: unknown -Scope '$Scope' (expected local|project|managed)")
        exit 2
    }
}
