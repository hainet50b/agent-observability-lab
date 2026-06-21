[CmdletBinding()]
param(
    [string]$Scope = 'local',
    [string]$Target,
    [switch]$Managed,
    [string]$Config
)

$ErrorActionPreference = 'Stop'

$StackDir = Split-Path -Parent $PSScriptRoot
$ComponentsDir = Join-Path $PSScriptRoot '../../../components'

if ($Managed) {
    $Scope = 'managed'
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
        'collector.otlp_endpoint' {
            $OtlpEndpoint = $v.Trim()
        }
    }
}
if (-not $OtlpEndpoint) {
    [Console]::Error.WriteLine("FAIL: ${Config}: missing or empty key 'collector.otlp_endpoint'.")
    exit 2
}

switch ($Scope) {
    'local' {
        if (-not $Target) {
            $Target = $StackDir
        }
        & (Join-Path $ComponentsDir 'agents/claude-code/scripts/setup-telemetry.ps1') -TargetDir $Target -OtlpEndpoint $OtlpEndpoint
    }
    'managed' {
        & (Join-Path $ComponentsDir 'agents/claude-code/scripts/setup-managed.ps1') `
            -LogsEndpoint "$OtlpEndpoint/v1/logs" -TracesEndpoint "$OtlpEndpoint/v1/traces" -MetricsEndpoint "$OtlpEndpoint/v1/metrics"
    }
    default {
        [Console]::Error.WriteLine("FAIL: unknown -Scope '$Scope' (expected local|managed)")
        exit 2
    }
}
