$script:McAgent = 'claude'

function Get-McManagedRoot($Os) {
    switch ($Os) {
        'windows' { 'C:\Program Files\ClaudeCode' }
        'macos' { '/Library/Application Support/ClaudeCode' }
        'linux' { '/etc/claude' }
        default { Write-McFatal "no Claude managed-settings path for os '$Os'" }
    }
}

function Get-McManifest {
    param([string]$Os, [string[]]$Sources = @())
    $root = Get-McManagedRoot $Os
    [pscustomobject]@{ Key = 'managed-settings'; Source = $Sources[0]; Target = (Join-Path $root 'managed-settings.json') }
    if ($script:McWithHooks) { Get-McHookManifestItem (Join-Path $root 'hooks') }
}
