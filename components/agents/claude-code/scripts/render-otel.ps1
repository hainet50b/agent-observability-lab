# render-otel.ps1 — render the Claude Code agent's telemetry `env` block into
# <TargetDir>/.claude/settings.local.json (PowerShell mirror of render-otel.sh).
#
# The telemetry env knobs live once in the agent-owned template
# ../otel.template.json. This fills the four non-agent values — the three FULL
# per-signal OTLP endpoints and the headers — and merges the `env` block into
# the target's settings. The caller supplies the full per-signal endpoints; this
# script does no path construction (the /v1/<signal> path is the backend's).
#
# Telemetry only: renders `env`. The prompt-capture/audit hook belongs to the
# separate claude-code-elastic-audit stack (render-hook), not here.
#
# JSON key-merge, create-if-absent: writes { "env": {…} } when absent; adds
# `env` to an existing file only if it has none; never clobbers an existing
# `env`. Re-running is a no-op. Uses built-in JSON cmdlets (no deps).
#
# Usage: render-otel.ps1 -TargetDir <dir> -LogsEndpoint <url> -TracesEndpoint <url> -MetricsEndpoint <url> [-OtlpHeaders <str>]

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$LogsEndpoint,
    [Parameter(Mandatory = $true)][string]$TracesEndpoint,
    [Parameter(Mandatory = $true)][string]$MetricsEndpoint,
    [string]$OtlpHeaders = ''
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
$Template = Join-Path $ComponentDir 'otel.template.json'

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) {
    Write-Error "FAIL: template not found: $Template"
    exit 1
}

$out = Join-Path $TargetDir '.claude/settings.local.json'

# Never clobber an existing env block (create-if-absent).
if (Test-Path -LiteralPath $out) {
    $existing = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
    if ($existing.PSObject.Properties.Name -contains 'env') {
        Write-Host "kept existing env in $out (delete to regenerate)"
        exit 0
    }
}

# Render the template's env block: fill the four tokens, drop _comment.
$rendered = (Get-Content -Raw -LiteralPath $Template) `
    -replace '@@OTLP_LOGS_ENDPOINT@@', $LogsEndpoint `
    -replace '@@OTLP_TRACES_ENDPOINT@@', $TracesEndpoint `
    -replace '@@OTLP_METRICS_ENDPOINT@@', $MetricsEndpoint `
    -replace '@@OTLP_HEADERS@@', $OtlpHeaders
$envBlock = ($rendered | ConvertFrom-Json).env

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null

if (Test-Path -LiteralPath $out) {
    # File exists but has no env — add `env` only, leave everything else intact.
    $cfg = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName 'env' -NotePropertyValue $envBlock -Force
    $cfg | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $out -Encoding utf8
    Write-Host "added env to $out"
}
else {
    [pscustomobject]@{ env = $envBlock } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $out -Encoding utf8
    Write-Host "wrote $out"
}
