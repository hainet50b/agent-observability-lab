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
$config = Join-Path $TargetDir '.codex/config.toml'
$hooksOwned = $false
$configMarker = "$config$script:CpMarkerSuffix"
if ((Test-Path -LiteralPath $configMarker -PathType Leaf) -and
    ((Get-CpMarkerField $configMarker 'endpoint') -eq $Endpoint)) {
    $hooksOwned = $true
}

$targets = @(
    @{ Key = 'config'; Target = $config },
    @{ Key = 'agent-audit'; Target = (Join-Path $TargetDir '.codex/hooks/agent-audit.conf') },
    @{ Key = 'agent-audit'; Target = (Join-Path $TargetDir '.codex/hooks/recipient.pem') },
    @{ Key = 'auth'; Target = (Join-Path $TargetDir '.codex/auth.json') },
    @{ Key = 'gitignore'; Target = (Join-Path $TargetDir '.codex/.gitignore') }
)
foreach ($t in $targets) {
    if (-not (Remove-CpFile $t.Key $Endpoint $t.Target)) { $failed = $true }
}

$hooksDir = Join-Path $TargetDir '.codex/hooks'
if ($hooksOwned -and (Test-Path -LiteralPath $hooksDir)) {
    Remove-Item -LiteralPath $hooksDir -Recurse -Force
    Write-CpLog "hooks: removed $hooksDir"
}

if ($failed) { Write-CpFatal 'one or more files were refused (see above); nothing foreign was removed' }

$agentHome = Join-Path $TargetDir '.codex'
if ((Test-Path -LiteralPath $agentHome) -and -not (Get-ChildItem -LiteralPath $agentHome -Force)) {
    Remove-Item -LiteralPath $agentHome -Force
    Write-CpLog "removed empty $agentHome"
}
