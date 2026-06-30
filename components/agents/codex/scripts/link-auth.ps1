[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CodexHome,
    [Parameter(Mandatory = $true)][string]$Endpoint,
    [string]$Source
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
. (Join-Path $ComponentDir '../shared/config-place/lib/config-place-core.ps1')

if (-not $Source) {
    $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $Source = Join-Path $userHome '.codex/auth.json'
}

$target = Join-Path $CodexHome 'auth.json'

if (-not (Test-Path -LiteralPath $Source)) {
    Write-CpLog "auth: no $Source found; run 'codex login' under CODEX_HOME ($CodexHome)"
    exit 0
}
if (Test-Path -LiteralPath $target) {
    Write-CpLog "auth: existing auth.json kept at $target"
    exit 0
}

New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
$linked = $false
try {
    New-Item -ItemType SymbolicLink -Path $target -Target $Source -ErrorAction Stop | Out-Null
    $linked = $true
}
catch {
    Copy-Item -LiteralPath $Source -Destination $target -Force
}
if ($linked) {
    Write-CpLog "auth: linked $target -> $Source"
}
else {
    Write-CpLog "auth: copied $Source to $target (not a link; a copy can go stale on token refresh)"
}
Write-CpMarker -Marker "$target$script:CpMarkerSuffix" -Agent 'codex' -Endpoint $Endpoint -Target $target
