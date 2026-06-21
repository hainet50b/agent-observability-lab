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
    [pscustomobject]@{ Key = 'requirements'; Source = $Sources[0]; Target = $requirementsTarget }
    [pscustomobject]@{ Key = 'managed_config'; Source = $Sources[1]; Target = $managedTarget }
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
