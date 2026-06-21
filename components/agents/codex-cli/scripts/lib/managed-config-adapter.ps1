$script:McAgent = 'codex-cli'

function Get-McManifest {
    param([string]$Os, [string[]]$Sources = @())
    switch ($Os) {
        'windows' {
            $requirementsTarget = Join-Path $env:ProgramData 'OpenAI\Codex\requirements.toml'
            $managedTarget = Join-Path $HOME '.codex\managed_config.toml'
        }
        'macos' {
            $requirementsTarget = '/etc/codex/requirements.toml'
            $managedTarget = '/etc/codex/managed_config.toml'
        }
        'linux' {
            $requirementsTarget = '/etc/codex/requirements.toml'
            $managedTarget = '/etc/codex/managed_config.toml'
        }
        default { Write-McFatal "no Codex managed-config path for os '$Os'" }
    }
    # requirements.toml is the hook-enforcement layer — placed only when hooks are
    # deployed (--with-hooks). A telemetry-only managed deploy places managed_config.toml
    # alone (symmetric with Claude's env-only managed-settings.json).
    if ($script:McWithHooks) {
        [pscustomobject]@{ Key = 'requirements'; Source = $Sources[0]; Target = $requirementsTarget }
    }
    # managed_config.toml carries only telemetry defaults; with no telemetry it
    # would be just a comment, so place it only when telemetry is present.
    if ($script:McWithTelemetry) {
        [pscustomobject]@{ Key = 'managed_config'; Source = $Sources[1]; Target = $managedTarget }
    }
    if ($script:McWithHooks) {
        Get-McHookManifestItem (Join-Path (Split-Path -Parent $requirementsTarget) 'hooks')
    }
}

function Get-McManagedRoot($Os) {
    switch ($Os) {
        'windows' { Join-Path $env:ProgramData 'OpenAI\Codex' }
        'macos' { '/etc/codex' }
        'linux' { '/etc/codex' }
        default { Write-McFatal "no Codex managed-config path for os '$Os'" }
    }
}
