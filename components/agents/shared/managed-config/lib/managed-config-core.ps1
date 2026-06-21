$ErrorActionPreference = 'Stop'

$script:McMarkerSuffix = '.lab-managed'
$script:McFailed = $false
$script:McEndpoint = ''
$script:McWithHooks = $false
$script:McHooksStage = ''

function Write-McLog($Message) {
    [Console]::Error.WriteLine("[managed-config] $Message")
}

function Write-McFatal($Message) {
    [Console]::Error.WriteLine("[managed-config] FATAL: $Message")
    exit 1
}

function Test-McAdapter {
    if (-not $script:McAgent) { Write-McFatal 'adapter did not set $McAgent' }
    if (-not (Get-Command -Name Get-McManifest -ErrorAction SilentlyContinue)) {
        Write-McFatal 'adapter did not define Get-McManifest'
    }
}

function Get-McPlatform {
    $runtimeInformation = [System.Runtime.InteropServices.RuntimeInformation]
    $osPlatform = [System.Runtime.InteropServices.OSPlatform]
    if ($runtimeInformation::IsOSPlatform($osPlatform::Windows)) { return 'windows' }
    if ($runtimeInformation::IsOSPlatform($osPlatform::OSX)) { return 'macos' }
    if ($runtimeInformation::IsOSPlatform($osPlatform::Linux)) { return 'linux' }
    Write-McFatal 'unsupported OS'
}

function Assert-McTty {
    if ([Console]::IsInputRedirected) {
        Write-McFatal 'input is not a TTY — placement is always interactive (there is no -Yes); nothing was changed'
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
    [System.IO.File]::WriteAllText($Marker, ($lines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
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

function Copy-McFile($Source, $Target) {
    $dir = Split-Path -Parent $Target
    try {
        if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    }
    catch {
        Write-McFatal "cannot create $dir — rerun with privileges (run as Administrator)"
    }
    try {
        Copy-Item -LiteralPath $Source -Destination $Target -Force
    }
    catch {
        Write-McFatal "cannot write $Target (permission denied?) — install it manually with elevated privileges (e.g. Copy-Item '$Source' '$Target' as Administrator)"
    }
}

function Remove-McFile($Path) {
    Remove-Item -LiteralPath $Path -Force
}

function Install-McManagedFile($Item) {
    $key = $Item.Key
    $source = $Item.Source
    $target = $Item.Target
    $marker = "$target$script:McMarkerSuffix"
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { Write-McFatal "${key}: source content not found: $source" }

    if (-not (Test-Path -LiteralPath $target)) {
        Write-McLog "${key}: $target does not exist (new file)"
        Show-McContent $source
        if (-not (Confirm-McProceed "Place $key at $target?")) { return }
        Copy-McFile $source $target
        try { Write-McMarker $marker $target }
        catch {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            Write-McFatal "${key}: could not write provenance marker $marker — rolled back $target so it is not left unmarked"
        }
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
    Copy-McFile $source $target
    try { Write-McMarker $marker $target }
    catch { Write-McFatal "${key}: updated $target but could not rewrite marker $marker — remove $target manually" }
    Write-McLog "${key}: updated $target"
}

function Remove-McManagedFile($Item) {
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
        Remove-McFile $target
    }
    catch {
        Write-McFatal "cannot remove $target (permission denied?) — remove it manually with elevated privileges (e.g. Remove-Item '$target' as Administrator)"
    }
    try {
        Remove-McFile $marker
    }
    catch {
        Write-McLog "${key}: removed $target but could not remove marker $marker — remove it manually"
    }
    Write-McLog "${key}: removed $target and its marker"
}

function Add-McHookStage($ComponentDir, $EsUrl) {
    $hooksSrc = Join-Path $ComponentDir 'hooks'
    $coreSrc = Join-Path $ComponentDir '../shared/agent-audit/lib'
    $confTemplate = Join-Path (Join-Path $ComponentDir 'templates') 'agent-audit.template.conf'
    if (-not (Test-Path -LiteralPath $confTemplate -PathType Leaf)) { Write-McFatal "conf template not found: $confTemplate" }
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ('mc-hooks-' + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path (Join-Path $stage 'lib') | Out-Null
    Copy-Item -LiteralPath (Join-Path $hooksSrc 'agent-audit.sh'), (Join-Path $hooksSrc 'agent-audit.ps1') -Destination $stage -Force
    Copy-Item -LiteralPath (Join-Path $hooksSrc 'lib/adapter.sh'), (Join-Path $hooksSrc 'lib/adapter.ps1') -Destination (Join-Path $stage 'lib') -Force
    Copy-Item -LiteralPath (Join-Path $coreSrc 'agent-audit-core.sh'), (Join-Path $coreSrc 'agent-audit-core.ps1') -Destination (Join-Path $stage 'lib') -Force
    $conf = (Get-Content -Raw -LiteralPath $confTemplate) -replace '@@ES_URL@@', $EsUrl
    [System.IO.File]::WriteAllText((Join-Path $stage 'agent-audit.conf'), $conf, [System.Text.UTF8Encoding]::new($false))
    $script:McHooksStage = $stage
    return $stage
}

function Get-McHookManifestItem($HooksTarget) {
    foreach ($rel in @('agent-audit.sh', 'agent-audit.ps1', 'agent-audit.conf', 'lib/adapter.sh', 'lib/adapter.ps1', 'lib/agent-audit-core.sh', 'lib/agent-audit-core.ps1')) {
        [pscustomobject]@{ Key = "hook:$rel"; Source = (Join-Path $script:McHooksStage $rel); Target = (Join-Path $HooksTarget $rel) }
    }
}

function Invoke-McPlace($Endpoint, $Sources) {
    $script:McEndpoint = $Endpoint
    Test-McAdapter
    if (-not $script:McEndpoint) { Write-McFatal 'no endpoint provided' }
    $os = Get-McPlatform
    Assert-McTty
    $items = @(Get-McManifest -Os $os -Sources $Sources)
    if ($items.Count -eq 0) { Write-McFatal "manifest empty for os '$os' — nothing to place" }
    foreach ($item in $items) { Install-McManagedFile $item }
    if ($script:McFailed) { Write-McFatal 'one or more managed files were refused (see above); nothing foreign was touched' }
}

function Invoke-McTeardown {
    Test-McAdapter
    $os = Get-McPlatform
    Assert-McTty
    $items = @(Get-McManifest -Os $os)
    if ($items.Count -eq 0) { Write-McFatal "manifest empty for os '$os' — nothing to remove" }
    foreach ($item in $items) { Remove-McManagedFile $item }
    if ($script:McFailed) { Write-McFatal 'one or more managed files were refused (see above)' }
}


