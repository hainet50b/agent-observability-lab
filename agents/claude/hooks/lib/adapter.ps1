$script:Provider = 'anthropic'
$script:AgentName = 'claude'

# Relative-path candidates for config-provenance runtime_hash (T8), mirroring
# the render-time entries in agent-config/src/agents/claude.rs. `$HomeDir` is
# the local/project agent home (".claude"); `$TargetRoot` is its parent,
# where the Local-scope ".mcp.json" sibling lands.
function Add-AuditProvenanceLocalManifest($HomeDir, $TargetRoot) {
    $entries = @(
        @('.gitignore', '.claude/.gitignore'),
        @('hooks/agent-audit.conf', '.claude/hooks/agent-audit.conf'),
        @('hooks/agent-audit.ps1', '.claude/hooks/agent-audit.ps1'),
        @('hooks/lib/adapter.ps1', '.claude/hooks/lib/adapter.ps1'),
        @('hooks/lib/agent-audit-core.ps1', '.claude/hooks/lib/agent-audit-core.ps1'),
        @('hooks/lib/seal.ps1', '.claude/hooks/lib/seal.ps1'),
        @('hooks/recipient.pem', '.claude/hooks/recipient.pem'),
        @('settings.local.json', '.claude/settings.local.json')
    )
    foreach ($entry in $entries) {
        $script:ProvenanceAbs.Add((Join-Path $HomeDir $entry[0]))
        $script:ProvenanceRel.Add($entry[1])
    }
    $script:ProvenanceAbs.Add((Join-Path $TargetRoot '.mcp.json'))
    $script:ProvenanceRel.Add('.mcp.json')
}

# Same, for a managed cell: `$ManagedRoot` is the host managed root
# (agent-config/src/agents/claude.rs managed_root), `$Executor` is the owning
# config's executor (the hook's own directory name under managed_root/hooks).
function Add-AuditProvenanceManagedManifest($Executor, $ManagedRoot) {
    $rootRel = (($ManagedRoot -replace '\\', '/') -replace '^([A-Za-z]):', '$1').Trim('/')
    $entries = @(
        "hooks/$Executor/agent-audit.conf",
        "hooks/$Executor/agent-audit.ps1",
        "hooks/$Executor/lib/adapter.ps1",
        "hooks/$Executor/lib/agent-audit-core.ps1",
        "hooks/$Executor/lib/seal.ps1",
        "hooks/$Executor/recipient.pem",
        "managed-settings.d/10-$Executor.json"
    )
    foreach ($suffix in $entries) {
        $script:ProvenanceAbs.Add((Join-Path $ManagedRoot $suffix))
        $script:ProvenanceRel.Add("$rootRel/$suffix")
    }
}

function Get-RuntimeIdentity {
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    $userName = if ($env:USER) { $env:USER } elseif ($env:USERNAME) { $env:USERNAME } else { [Environment]::UserName }
    $userName = NullIfEmpty $userName
    $userId = try { ([string](& whoami) 2>$null).Trim() } catch { $null }
    $userId = NullIfEmpty $userId

    $hostName = NullIfEmpty ([System.Net.Dns]::GetHostName())

    $claudeConfig = if ($env:CLAUDE_CONFIG) { $env:CLAUDE_CONFIG } else { Join-Path $HOME '.claude.json' }
    $accountId = $null; $accountName = $null; $accountEmail = $null; $organizationId = $null; $organizationName = $null
    if (Test-Path -LiteralPath $claudeConfig -PathType Leaf) {
        try {
            $oauth = ([System.IO.File]::ReadAllText($claudeConfig) | ConvertFrom-Json).oauthAccount
            if ($oauth) {
                $accountId = NullIfEmpty $oauth.accountUuid
                $accountName = NullIfEmpty $oauth.displayName
                $accountEmail = NullIfEmpty $oauth.emailAddress
                $organizationId = NullIfEmpty $oauth.organizationUuid
                $organizationName = NullIfEmpty $oauth.organizationName
            }
        }
        catch { Write-Verbose "fail-open: $_" }
    }

    return [ordered]@{
        ts           = $ts
        user         = [ordered]@{ id = $userId; name = $userName }
        host         = [ordered]@{ name = $hostName; hostname = $hostName }
        account      = [ordered]@{ id = $accountId; name = $accountName; email = $accountEmail }
        organization = [ordered]@{ id = $organizationId; name = $organizationName }
    }
}
