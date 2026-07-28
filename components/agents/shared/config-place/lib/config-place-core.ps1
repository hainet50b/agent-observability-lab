# Non-interactive, marker-aware placement for local/project bundle files.
# Reuses the managed-config marker format exactly: a per-file sidecar
# <target>.managed with lines tool=, agent=, endpoint=, placed_at=, target=.
# Placement is scriptable with NO prompt and NO -Yes (local/project are
# "safe, scriptable, no confirmation" per SPEC); foreign or endpoint-mismatched
# targets fail loud and are never touched.

$script:CpMarkerSuffix = '.managed'
$script:CpTool = 'agent-observability-lab'

function Write-CpLog($Message) {
    [Console]::Error.WriteLine("[config-place] $Message")
}

function Write-CpFatal($Message) {
    # throw (not exit): these helpers are dot-sourced into render scripts that
    # are themselves invoked via `&` from setup-telemetry/setup-audit; `exit`
    # would only end the inner `&` call, leaving the parent at exit 0. With
    # $ErrorActionPreference='Stop' a throw propagates and fails the run loud.
    [Console]::Error.WriteLine("[config-place] FATAL: $Message")
    throw "[config-place] $Message"
}

function Get-CpMarkerField($Marker, $Key) {
    if (-not (Test-Path -LiteralPath $Marker -PathType Leaf)) { return $null }
    foreach ($line in Get-Content -LiteralPath $Marker) {
        $i = $line.IndexOf('=')
        if ($i -lt 0) { continue }
        if ($line.Substring(0, $i) -eq $Key) { return $line.Substring($i + 1) }
    }
    return $null
}

function Write-CpMarker($Marker, $Agent, $Endpoint, $Target) {
    $placedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $lines = @(
        "tool=$script:CpTool"
        "agent=$Agent"
        "endpoint=$Endpoint"
        "placed_at=$placedAt"
        "target=$Target"
    )
    [System.IO.File]::WriteAllText($Marker, ($lines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
}

# Returns $true if the target is ours (lab marker with matching endpoint),
# $false if it does not exist, and dies loud if it exists foreign / mismatched.
function Test-CpOursOrAbsent($Key, $Endpoint, $Target) {
    $marker = "$Target$script:CpMarkerSuffix"
    if (-not (Test-Path -LiteralPath $Target)) { return $false }
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        Write-CpFatal "${Key}: REFUSED — $Target exists with no provenance marker (not placed by this tool). Never touched."
    }
    $markerEndpoint = Get-CpMarkerField $marker 'endpoint'
    if ($markerEndpoint -ne $Endpoint) {
        Write-CpFatal "${Key}: REFUSED — $Target carries a different endpoint ($markerEndpoint); run teardown first. Not touched."
    }
    return $true
}

# Place a whole rendered file. ABSENT -> write + mark. OURS -> overwrite + mark.
# FOREIGN / mismatch -> die loud (nothing written).
function Set-CpFile($Key, $Agent, $Endpoint, $Source, $Target) {
    $marker = "$Target$script:CpMarkerSuffix"
    Test-CpOursOrAbsent -Key $Key -Endpoint $Endpoint -Target $Target | Out-Null
    $dir = Split-Path -Parent $Target
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item -LiteralPath $Source -Destination $Target -Force
    Write-CpMarker -Marker $marker -Agent $Agent -Endpoint $Endpoint -Target $Target
    Write-CpLog "${Key}: wrote $Target"
}

# Self-ignore a materialized agent-home: place <home>/.gitignore = "*" so the
# surrounding project's git ignores the whole bundle (config + secrets + runtime
# state) without touching the project's own ignore rules. Same marker-aware path
# as Set-CpFile, keyed on the deploy endpoint — foreign .gitignore is refused,
# teardown removes the lab-placed one. Idempotent across the render scripts that
# share an agent-home in one deploy (they pass the same endpoint).
function Set-CpSelfIgnore($Agent, $Endpoint, $AgentHome) {
    $tmp = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmp, "*`n", [System.Text.UTF8Encoding]::new($false))
    try { Set-CpFile -Key 'gitignore' -Agent $Agent -Endpoint $Endpoint -Source $tmp -Target (Join-Path $AgentHome '.gitignore') }
    finally { Remove-Item -LiteralPath $tmp -Force }
}

# Append a rendered section to a shared single-file config (Codex config.toml).
# ABSENT -> create with the block + mark. OURS -> append the block (separated by
# a blank line), or skip when <Sentinel> already present (idempotent re-run).
# FOREIGN / mismatch -> die loud (nothing written). The block is LF-normalized
# and the file is written without a BOM.
function Add-CpSection($Key, $Agent, $Endpoint, $Block, $Target, $Sentinel) {
    $marker = "$Target$script:CpMarkerSuffix"
    $blockLf = ($Block -replace "`r`n", "`n")
    $dir = Split-Path -Parent $Target
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (Test-CpOursOrAbsent -Key $Key -Endpoint $Endpoint -Target $Target) {
        if (Select-String -LiteralPath $Target -SimpleMatch $Sentinel -Quiet) {
            Write-CpLog "${Key}: already present in $Target — no-op."
            return
        }
        $existing = ((Get-Content -Raw -LiteralPath $Target) -replace "`r`n", "`n").TrimEnd("`n")
        $combined = $existing + "`n`n" + $blockLf
        [System.IO.File]::WriteAllText($Target, $combined, [System.Text.UTF8Encoding]::new($false))
        Write-CpLog "${Key}: appended to $Target"
    }
    else {
        [System.IO.File]::WriteAllText($Target, $blockLf, [System.Text.UTF8Encoding]::new($false))
        Write-CpMarker -Marker $marker -Agent $Agent -Endpoint $Endpoint -Target $Target
        Write-CpLog "${Key}: wrote $Target"
    }
}

# Remove a lab-placed file and its marker. A target with NO lab marker is a
# benign skip (returns $true) — it is the user's own file, not ours. A target
# whose marker endpoint DIFFERS is refused (returns $false) — another deploy's.
function Remove-CpFile($Key, $Endpoint, $Target) {
    $marker = "$Target$script:CpMarkerSuffix"
    if (-not (Test-Path -LiteralPath $Target) -and -not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        Write-CpLog "${Key}: nothing to remove ($Target absent)"
        return $true
    }
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        Write-CpLog "${Key}: leaving $Target — not placed by this tool (your own login/config). Not an error."
        return $true
    }
    $markerEndpoint = Get-CpMarkerField $marker 'endpoint'
    if ($markerEndpoint -ne $Endpoint) {
        Write-CpLog "${Key}: REFUSED — $Target carries a different endpoint ($markerEndpoint). Not removed."
        return $false
    }
    Remove-Item -LiteralPath $Target -Force
    try { Remove-Item -LiteralPath $marker -Force }
    catch { Write-CpLog "${Key}: removed $Target but could not remove marker $marker — remove it manually" }
    Write-CpLog "${Key}: removed $Target and its marker"
    return $true
}
