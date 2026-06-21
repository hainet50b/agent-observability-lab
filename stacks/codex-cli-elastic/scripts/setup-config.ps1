[CmdletBinding()]
param(
    [string]$Scope = 'local',
    [string]$Target,
    [switch]$Teardown,
    [switch]$WithHooks,
    [string]$Config
)

$ErrorActionPreference = 'Stop'

$StackDir = Split-Path -Parent $PSScriptRoot
$ComponentsDir = Join-Path $PSScriptRoot '../../../components'

if ($Teardown -and $Scope -ne 'managed') {
    [Console]::Error.WriteLine('FAIL: -Teardown is only valid with -Scope managed')
    exit 1
}

if (-not $Config) {
    $Config = Join-Path $StackDir 'setup.conf'
}
if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) {
    [Console]::Error.WriteLine("FAIL: config file not found: $Config")
    exit 2
}

foreach ($line in Get-Content -LiteralPath $Config) {
    if ($line -match '^\s*#' -or $line -notmatch '=') {
        continue
    }
    $k, $v = $line -split '=', 2
    switch ($k.Trim()) {
        'telemetry.apm_server.endpoint' {
            $OtlpEndpoint = $v.Trim()
        }
    }
}
if (-not $OtlpEndpoint) {
    [Console]::Error.WriteLine("FAIL: ${Config}: missing or empty key 'telemetry.apm_server.endpoint'.")
    exit 2
}

# Optional secret overlay (gitignored): telemetry.apm_server.api_key.
# Absent file or key -> empty, no error (no auth header rendered).
$OtlpApiKey = ''
$LocalConfig = Join-Path $StackDir 'setup.local.conf'
if (Test-Path -LiteralPath $LocalConfig -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $LocalConfig) {
        if ($line -match '^\s*#' -or $line -notmatch '=') {
            continue
        }
        $k, $v = $line -split '=', 2
        if ($k.Trim() -eq 'telemetry.apm_server.api_key') {
            $OtlpApiKey = $v.Trim()
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
        & (Join-Path $ComponentsDir 'agents/codex-cli/scripts/setup-telemetry.ps1') -TargetDir $Target -OtlpEndpoint $OtlpEndpoint -ApiKey $OtlpApiKey
        & (Join-Path $ComponentsDir 'agents/codex-cli/scripts/render-mcp.ps1') -TargetDir $Target
    }
    'project' {
        if (-not $Target) {
            [Console]::Error.WriteLine('FAIL: -Scope project requires -Target <dir>')
            exit 2
        }
        & (Join-Path $ComponentsDir 'agents/codex-cli/scripts/setup-telemetry.ps1') -TargetDir $Target -OtlpEndpoint $OtlpEndpoint -ApiKey $OtlpApiKey
    }
    'managed' {
        if ($Teardown) {
            $TeardownArgs = @{}
            if ($WithHooks) { $TeardownArgs['WithHooks'] = $true }
            & (Join-Path $ComponentsDir 'agents/codex-cli/scripts/teardown-managed.ps1') @TeardownArgs
        }
        else {
            & (Join-Path $ComponentsDir 'agents/codex-cli/scripts/setup-managed.ps1') `
                -LogsEndpoint "$OtlpEndpoint/v1/logs" -TracesEndpoint "$OtlpEndpoint/v1/traces" -MetricsEndpoint "$OtlpEndpoint/v1/metrics"
        }
    }
    default {
        [Console]::Error.WriteLine("FAIL: unknown -Scope '$Scope' (expected local|project|managed)")
        exit 2
    }
}
