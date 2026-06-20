$script:Provider = 'anthropic'
$script:AgentName = 'claude-code'
$script:UserPromptTurnIdSupported = $false

function Get-RuntimeIdentity {
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    $userName = if ($env:USER) { $env:USER } elseif ($env:USERNAME) { $env:USERNAME } else { [Environment]::UserName }
    $userName = NullIfEmpty $userName
    $userId = try { ([string](& whoami) 2>$null).Trim() } catch { $null }
    $userId = NullIfEmpty $userId

    $hostName = NullIfEmpty ([System.Net.Dns]::GetHostName())

    $claudeConfig = if ($env:CLAUDE_CONFIG) { $env:CLAUDE_CONFIG } else { Join-Path $HOME '.claude.json' }
    $accountId = $null; $accountName = $null; $accountEmail = $null; $orgId = $null; $orgName = $null
    if (Test-Path -LiteralPath $claudeConfig -PathType Leaf) {
        try {
            $oauth = (Get-Content -Raw -LiteralPath $claudeConfig | ConvertFrom-Json).oauthAccount
            if ($oauth) {
                $accountId = NullIfEmpty $oauth.accountUuid
                $accountName = NullIfEmpty $oauth.displayName
                $accountEmail = NullIfEmpty $oauth.emailAddress
                $orgId = NullIfEmpty $oauth.organizationUuid
                $orgName = NullIfEmpty $oauth.organizationName
            }
        }
        catch { Write-Verbose "fail-open: $_" }
    }

    return [ordered]@{
        ts           = $ts
        user         = [ordered]@{ id = $userId; name = $userName }
        host         = [ordered]@{ name = $hostName; hostname = $hostName }
        account      = [ordered]@{ id = $accountId; name = $accountName; email = $accountEmail }
        organization = [ordered]@{ id = $orgId; name = $orgName }
    }
}
