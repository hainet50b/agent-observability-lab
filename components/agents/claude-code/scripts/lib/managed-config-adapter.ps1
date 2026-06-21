$script:McAgent = 'claude-code'

function Get-McManifest {
    param([string]$Os, [string[]]$Sources = @())
    switch ($Os) {
        'windows' { $target = 'C:\ProgramData\ClaudeCode\managed-settings.json' }
        'macos' { $target = '/Library/Application Support/ClaudeCode/managed-settings.json' }
        'linux' { $target = '/etc/claude-code/managed-settings.json' }
        default { Write-McFatal "no Claude managed-settings path for os '$Os'" }
    }
    [pscustomobject]@{ Key = 'managed-settings'; Source = $Sources[0]; Target = $target }
}



