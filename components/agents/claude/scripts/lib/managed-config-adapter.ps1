$script:McAgent = 'claude'

function Get-McManagedRoot($Os) {
    switch ($Os) {
        'windows' { 'C:\Program Files\ClaudeCode' }
        'macos' { '/Library/Application Support/ClaudeCode' }
        'linux' { '/etc/claude-code' }
        default { Write-McFatal "no Claude managed-settings path for os '$Os'" }
    }
}

function Get-McManifest {
    param([string]$Os, [string[]]$Sources = @())
    $root = Get-McManagedRoot $Os
    $sep = if ($Os -eq 'windows') { '\' } else { '/' }
    [pscustomobject]@{ Key = 'managed-settings'; Source = $Sources[0]; Target = "$root${sep}managed-settings.d${sep}10-observability.json" }
    if ($script:McWithHooks) { Get-McHookManifestItem "$root${sep}hooks" (Get-McHookFlavor $Os) }
}
