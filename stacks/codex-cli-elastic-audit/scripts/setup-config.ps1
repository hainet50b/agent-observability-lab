[CmdletBinding()]
param(
    [string]$Scope = 'local',
    [string]$Target,
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

switch ($Scope) {
    'local' {
        if ($Target) {
            [Console]::Error.WriteLine('FAIL: -Scope local does not take -Target (use -Scope project to deploy into a directory)')
            exit 2
        }
        $Target = $StackDir
        & (Join-Path $ComponentsDir 'agents/codex-cli/scripts/setup-audit.ps1') `
            -TargetDir $Target -EsUrl $Conf['agent_audit.elasticsearch.url'] `
            -ApiKey $ApiKey -TimeoutMs $Conf['agent_audit.elasticsearch.timeout_ms'] `
            -UserPromptEnabled $Conf['agent_audit.capture.user_prompt.enabled'] `
            -UserPromptContent $Conf['agent_audit.capture.user_prompt.content'] `
            -ToolCallEnabled $Conf['agent_audit.capture.tool_call.enabled'] `
            -ToolCallContent $Conf['agent_audit.capture.tool_call.content']
        & (Join-Path $ComponentsDir 'agents/codex-cli/scripts/render-mcp.ps1') -TargetDir $Target
    }
    'project' {
        if (-not $Target) {
            [Console]::Error.WriteLine('FAIL: -Scope project requires -Target <dir>')
            exit 2
        }
        & (Join-Path $ComponentsDir 'agents/codex-cli/scripts/setup-audit.ps1') `
            -TargetDir $Target -EsUrl $Conf['agent_audit.elasticsearch.url'] `
            -ApiKey $ApiKey -TimeoutMs $Conf['agent_audit.elasticsearch.timeout_ms'] `
            -UserPromptEnabled $Conf['agent_audit.capture.user_prompt.enabled'] `
            -UserPromptContent $Conf['agent_audit.capture.user_prompt.content'] `
            -ToolCallEnabled $Conf['agent_audit.capture.tool_call.enabled'] `
            -ToolCallContent $Conf['agent_audit.capture.tool_call.content']
    }
    'managed' {
        [Console]::Error.WriteLine('FAIL: managed scope (audit hooks) is not wired yet - see PRD deploy 4/4.')
        exit 2
    }
    default {
        [Console]::Error.WriteLine("FAIL: unknown -Scope '$Scope' (expected local|project|managed)")
        exit 2
    }
}
