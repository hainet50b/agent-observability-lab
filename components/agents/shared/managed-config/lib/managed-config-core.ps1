$ErrorActionPreference = 'Stop'

$script:McMarkerSuffix = '.lab-managed'
$script:McFailed = $false
$script:McEndpoint = ''

function Write-McLog($Message) {
    [Console]::Error.WriteLine("[managed-config] $Message")
}

function McFail($Message) {
    [Console]::Error.WriteLine("[managed-config] FATAL: $Message")
    exit 1
}

function Test-McAdapter {
    if (-not $script:McAgent) { McFail 'adapter did not set $McAgent' }
    if (-not (Get-Command -Name Get-McManifest -ErrorAction SilentlyContinue)) {
        McFail 'adapter did not define Get-McManifest'
    }
}

function Get-McPlatform {
    $rt = [System.Runtime.InteropServices.RuntimeInformation]
    $plat = [System.Runtime.InteropServices.OSPlatform]
    if ($rt::IsOSPlatform($plat::Windows)) { return 'windows' }
    if ($rt::IsOSPlatform($plat::OSX)) { return 'macos' }
    if ($rt::IsOSPlatform($plat::Linux)) { return 'linux' }
    McFail 'unsupported OS'
}

function Assert-McTty {
    if ([Console]::IsInputRedirected) {
        McFail 'input is not a TTY — placement is always interactive (there is no -Yes); nothing was changed'
    }
}

function Confirm-McProceed($Prompt) {
    $reply = Read-Host -Prompt "$Prompt [y/N]"
    if ($reply -match '^(y|Y|yes|YES)$') { return $true }
    Write-McLog 'declined — skipping'
    return $false
}

function Get-McMarkerField($Marker, $Key) {
    if (-not (Test-Path -LiteralPath $Marker -PathType Leaf)) { return $null }
    foreach ($line in Get-Content -LiteralPath $Marker) {
        $i = $line.IndexOf('=')
        if ($i -lt 0) { continue }
        if ($line.Substring(0, $i) -eq $Key) { return $line.Substring($i + 1) }
    }
    return $null
}

function Write-McMarker($Marker, $Target) {
    $placedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $lines = @(
        "agent=$script:McAgent"
        "endpoint=$script:McEndpoint"
        "placed_at=$placedAt"
        "target=$Target"
    )
    try {
        [System.IO.File]::WriteAllText($Marker, ($lines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        McFail "placed $Target but could not write provenance marker $Marker — remove $Target manually"
    }
}

function Show-McDiff($Target, $Source) {
    $diff = Compare-Object -ReferenceObject (Get-Content -LiteralPath $Target) -DifferenceObject (Get-Content -LiteralPath $Source)
    foreach ($d in $diff) {
        $sign = if ($d.SideIndicator -eq '=>') { '+' } else { '-' }
        [Console]::Error.WriteLine("  $sign $($d.InputObject)")
    }
}

function Show-McContent($Source) {
    Write-McLog 'content to be written:'
    foreach ($line in Get-Content -LiteralPath $Source) { [Console]::Error.WriteLine("  | $line") }
}

function Install-McFile($Source, $Target) {
    $dir = Split-Path -Parent $Target
    try {
        if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    }
    catch {
        McFail "cannot create $dir — rerun with privileges (run as Administrator)"
    }
    try {
        Copy-Item -LiteralPath $Source -Destination $Target -Force
    }
    catch {
        McFail "cannot write $Target (permission denied?) — install it manually with elevated privileges (e.g. Copy-Item '$Source' '$Target' as Administrator)"
    }
}

function McRemoveFile($Path) {
    Remove-Item -LiteralPath $Path -Force
}

function McPlaceOne($Item) {
    $key = $Item.Key
    $source = $Item.Source
    $target = $Item.Target
    $marker = "$target$script:McMarkerSuffix"
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { McFail "${key}: source content not found: $source" }

    if (-not (Test-Path -LiteralPath $target)) {
        Write-McLog "${key}: $target does not exist (new file)"
        Show-McContent $source
        if (-not (Confirm-McProceed "Place $key at $target?")) { return }
        Install-McFile $source $target
        Write-McMarker $marker $target
        Write-McLog "${key}: placed $target"
        return
    }

    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        Write-McLog "${key}: REFUSED — $target exists with no lab marker (foreign / real-org managed config). Never touched."
        $script:McFailed = $true
        return
    }

    $markerEndpoint = Get-McMarkerField $marker 'endpoint'
    if ($markerEndpoint -ne $script:McEndpoint) {
        Write-McLog "${key}: REFUSED — this host already enforces $markerEndpoint; run teardown first."
        $script:McFailed = $true
        return
    }

    if ((Get-Content -Raw -LiteralPath $source) -eq (Get-Content -Raw -LiteralPath $target)) {
        Write-McLog "${key}: already placed by the lab and identical — no-op."
        return
    }

    Write-McLog "${key}: $target was placed by the lab but the content changed:"
    Show-McDiff $target $source
    if (-not (Confirm-McProceed "Update $key at $target?")) { return }
    Install-McFile $source $target
    Write-McMarker $marker $target
    Write-McLog "${key}: updated $target"
}

function McTeardownOne($Item) {
    $key = $Item.Key
    $target = $Item.Target
    $marker = "$target$script:McMarkerSuffix"

    if (-not (Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        Write-McLog "${key}: nothing to remove ($target absent)"
        return
    }

    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        Write-McLog "${key}: REFUSED — $target has no lab marker (foreign / real-org config). Not removed."
        $script:McFailed = $true
        return
    }

    $markerAgent = Get-McMarkerField $marker 'agent'
    $markerEndpoint = Get-McMarkerField $marker 'endpoint'
    if (-not (Confirm-McProceed "Remove lab-placed $key at $target (agent='$markerAgent' endpoint='$markerEndpoint')?")) { return }
    try {
        McRemoveFile $target
    }
    catch {
        McFail "cannot remove $target (permission denied?) — remove it manually with elevated privileges (e.g. Remove-Item '$target' as Administrator)"
    }
    try {
        McRemoveFile $marker
    }
    catch {
        Write-McLog "${key}: removed $target but could not remove marker $marker — remove it manually"
    }
    Write-McLog "${key}: removed $target and its marker"
}

function Invoke-McPlace($Endpoint) {
    $script:McEndpoint = $Endpoint
    Test-McAdapter
    if (-not $script:McEndpoint) { McFail 'no endpoint provided' }
    $os = Get-McPlatform
    Assert-McTty
    $items = @(Get-McManifest -Os $os)
    if ($items.Count -eq 0) { McFail "manifest empty for os '$os' — nothing to place" }
    foreach ($item in $items) { McPlaceOne $item }
    if ($script:McFailed) { McFail 'one or more managed files were refused (see above); nothing foreign was touched' }
}

function Invoke-McTeardown {
    Test-McAdapter
    $os = Get-McPlatform
    Assert-McTty
    $items = @(Get-McManifest -Os $os)
    if ($items.Count -eq 0) { McFail "manifest empty for os '$os' — nothing to remove" }
    foreach ($item in $items) { McTeardownOne $item }
    if ($script:McFailed) { McFail 'one or more managed files were refused (see above)' }
}




