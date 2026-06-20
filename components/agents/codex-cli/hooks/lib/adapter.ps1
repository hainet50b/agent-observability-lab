$script:Provider = 'openai'
$script:AgentName = 'codex-cli'
$script:UserPromptTurnIdSupported = $true

function ConvertFrom-Base64Url($Value) {
    $t = $Value.Replace('-', '+').Replace('_', '/')
    switch ($t.Length % 4) { 2 { $t += '==' } 3 { $t += '=' } }
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($t))
}

function Get-CodexProviderIdentity($CodexHome) {
    $r = [ordered]@{ account_id = $null; account_email = $null; account_name = $null; org_id = $null; org_name = $null }
    try {
        $authFile = Join-Path $CodexHome 'auth.json'
        if (-not (Test-Path -LiteralPath $authFile)) { return $r }
        $auth = Get-Content -Raw -LiteralPath $authFile | ConvertFrom-Json
        $r.account_id = $auth.tokens.account_id
        $idToken = $auth.tokens.id_token
        if ($idToken) {
            $parts = ([string]$idToken).Split('.')
            if ($parts.Length -ge 2) {
                $claims = ConvertFrom-Base64Url $parts[1] | ConvertFrom-Json
                $r.account_email = $claims.email
                $r.account_name = $claims.name
                $orgs = $claims.'https://api.openai.com/auth'.organizations
                if ($orgs) {
                    $org = $orgs | Where-Object { $_.is_default -eq $true } | Select-Object -First 1
                    if (-not $org) { $org = $orgs | Select-Object -First 1 }
                    if ($org) { $r.org_id = $org.id; $r.org_name = $org.title }
                }
            }
        }
    }
    catch { Write-Verbose "fail-open: $_" }
    return $r
}

function Get-RuntimeIdentity {
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    $userName = if ($env:USER) { $env:USER } elseif ($env:USERNAME) { $env:USERNAME } else { [Environment]::UserName }
    if (-not $userName) { $userName = $null }
    $userId = try { ([string](& whoami) 2>$null).Trim() } catch { $null }
    if (-not $userId) { $userId = $null }

    $hostName = try { [System.Net.Dns]::GetHostName() } catch { $null }
    if (-not $hostName) { $hostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { $null } }

    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    $ident = Get-CodexProviderIdentity $codexHome

    return [ordered]@{
        ts           = $ts
        user         = [ordered]@{ id = $userId; name = $userName }
        host         = [ordered]@{ name = $hostName; hostname = $hostName }
        account      = [ordered]@{ id = $ident.account_id; name = $ident.account_name; email = $ident.account_email }
        organization = [ordered]@{ id = $ident.org_id; name = $ident.org_name }
    }
}
