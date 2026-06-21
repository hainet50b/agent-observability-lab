$script:McAgent = 'claude-code'
$script:McSource = ''

function Get-McManifest {
    param([string]$Os)
    switch ($Os) {
        'windows' { $target = 'C:\ProgramData\ClaudeCode\managed-settings.json' }
        'macos' { $target = '/Library/Application Support/ClaudeCode/managed-settings.json' }
        'linux' { $target = '/etc/claude-code/managed-settings.json' }
        default { McFail "no Claude managed-settings path for os '$Os'" }
    }
    [pscustomobject]@{ Key = 'managed-settings'; Source = $script:McSource; Target = $target }
}

