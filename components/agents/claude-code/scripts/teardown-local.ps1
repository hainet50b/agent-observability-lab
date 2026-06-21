[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$Endpoint
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir
. (Join-Path $ComponentDir '../shared/config-place/lib/config-place-core.ps1')

$failed = $false
$settings = Join-Path $TargetDir '.claude/settings.local.json'
$hooksOwned = $false
$settingsMarker = "$settings$script:CpMarkerSuffix"
if ((Test-Path -LiteralPath $settingsMarker -PathType Leaf) -and
    ((Get-CpMarkerField $settingsMarker 'endpoint') -eq $Endpoint)) {
    $hooksOwned = $true
}

$targets = @(
    @{ Key = 'settings'; Target = $settings },
    @{ Key = 'agent-audit'; Target = (Join-Path $TargetDir '.claude/agent-audit.conf') },
    @{ Key = 'mcp'; Target = (Join-Path $TargetDir '.mcp.json') },
    @{ Key = 'gitignore'; Target = (Join-Path $TargetDir '.claude/.gitignore') }
)
foreach ($t in $targets) {
    if (-not (Remove-CpFile $t.Key $Endpoint $t.Target)) { $failed = $true }
}

$hooksDir = Join-Path $TargetDir '.claude/hooks'
if ($hooksOwned -and (Test-Path -LiteralPath $hooksDir)) {
    Remove-Item -LiteralPath $hooksDir -Recurse -Force
    Write-CpLog "hooks: removed $hooksDir"
}

if ($failed) { Write-CpFatal 'one or more files were refused (see above); nothing foreign was removed' }
