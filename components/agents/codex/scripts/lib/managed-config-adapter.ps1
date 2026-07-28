$script:McAgent = 'codex'

function Get-McManifest {
    param([string]$Os, [string[]]$Sources = @())
    $root = Get-McManagedRoot $Os
    if ($Os -eq 'windows') {
        $sep = '\'
        # Codex reads managed_config.toml from the user profile on Windows: an
        # interactive place targets this host's $HOME, while a rendered bundle
        # carries a USERPROFILE/ placeholder the MDM layer must expand per user.
        $managedTarget = if ($script:McRenderMode) { '%USERPROFILE%\.codex\managed_config.toml' } else { Join-Path $HOME '.codex\managed_config.toml' }
    }
    else {
        $sep = '/'
        $managedTarget = "$root/managed_config.toml"
    }
    # requirements.toml is the hook-enforcement layer — placed only when hooks are
    # deployed (--with-hooks). A telemetry-only managed deploy places managed_config.toml
    # alone (symmetric with Claude's env-only managed fragment).
    if ($script:McWithHooks) {
        [pscustomobject]@{ Key = 'requirements'; Source = $Sources[0]; Target = "$root${sep}requirements.toml" }
    }
    # managed_config.toml carries only telemetry defaults; with no telemetry it
    # would be just a comment, so place it only when telemetry is present.
    if ($script:McWithTelemetry) {
        [pscustomobject]@{ Key = 'managed_config'; Source = $Sources[1]; Target = $managedTarget }
    }
    if ($script:McWithHooks) {
        Get-McHookManifestItem "$root${sep}hooks" (Get-McHookFlavor $Os)
    }
}

function Get-McManagedRoot($Os) {
    switch ($Os) {
        'windows' { 'C:\ProgramData\OpenAI\Codex' }
        'macos' { '/etc/codex' }
        'linux' { '/etc/codex' }
        default { Write-McFatal "no Codex managed-config path for os '$Os'" }
    }
}
