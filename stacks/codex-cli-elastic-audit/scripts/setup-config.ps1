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

foreach ($line in Get-Content -LiteralPath $Config) {
    if ($line -match '^\s*#' -or $line -notmatch '=') {
        continue
    }
    $k, $v = $line -split '=', 2
    switch ($k.Trim()) {
        'elasticsearch.url' {
            $EsUrl = $v.Trim()
        }
    }
}
if (-not $EsUrl) {
    [Console]::Error.WriteLine("FAIL: ${Config}: missing or empty key 'elasticsearch.url'.")
    exit 2
}

switch ($Scope) {
    'local' {
        if (-not $Target) {
            $Target = $StackDir
        }
        & (Join-Path $ComponentsDir 'agents/codex-cli/scripts/setup-audit.ps1') -TargetDir $Target -EsUrl $EsUrl
    }
    'managed' {
        [Console]::Error.WriteLine('FAIL: managed scope (audit hooks) is not wired yet - see PRD deploy 4/4.')
        exit 2
    }
    default {
        [Console]::Error.WriteLine("FAIL: unknown -Scope '$Scope' (expected local|managed)")
        exit 2
    }
}
