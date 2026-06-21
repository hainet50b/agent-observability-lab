$script:McAgent = 'codex-cli'
$script:McSourceRequirements = ''
$script:McSourceManagedConfig = ''

function Get-McManifest {
    param([string]$Os)
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
        default { McFail "no Codex managed-config path for os '$Os'" }
    }
    [pscustomobject]@{ Key = 'requirements'; Source = $script:McSourceRequirements; Target = $requirementsTarget }
    [pscustomobject]@{ Key = 'managed_config'; Source = $script:McSourceManagedConfig; Target = $managedTarget }
}

