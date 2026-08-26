$script:Provider = 'openai'
$script:AgentName = 'codex'

# Relative-path candidates for config-provenance runtime_hash (T8), mirroring
# the render-time entries in agent-config/src/agents/codex.rs. `$HomeDir` is
# the local/project agent home (".codex"); `$TargetRoot` is unused for Codex
# (no sibling root file — `[mcp_servers.*]` is folded into config.toml, and
# auth.json is a place-time symlink/copy, not a rendered manifest entry).
function Add-AuditProvenanceLocalManifest($HomeDir, $TargetRoot) {
    $entries = @(
        @('.gitignore', '.codex/.gitignore'),
        @('config.toml', '.codex/config.toml'),
        @('hooks/agent-audit.conf', '.codex/hooks/agent-audit.conf'),
        @('hooks/agent-audit.ps1', '.codex/hooks/agent-audit.ps1'),
        @('hooks/lib/adapter.ps1', '.codex/hooks/lib/adapter.ps1'),
        @('hooks/lib/agent-audit-core.ps1', '.codex/hooks/lib/agent-audit-core.ps1'),
        @('hooks/lib/seal.ps1', '.codex/hooks/lib/seal.ps1'),
        @('hooks/recipient.pem', '.codex/hooks/recipient.pem')
    )
    foreach ($entry in $entries) {
        $script:ProvenanceAbs.Add((Join-Path $HomeDir $entry[0]))
        $script:ProvenanceRel.Add($entry[1])
    }
}

# Same, for a managed cell (agent-config/src/agents/codex.rs managed_root /
# managed_entries). On Windows, `managed_config.toml` (telemetry) is written
# outside managed_root at `%USERPROFILE%/.codex/managed_config.toml` — a
# fixed rel name per `host_render_rel`'s dedicated %USERPROFILE% branch, not
# derived from `$ManagedRoot`.
function Add-AuditProvenanceManagedManifest($Executor, $ManagedRoot) {
    $rootRel = (($ManagedRoot -replace '\\', '/') -replace '^([A-Za-z]):', '$1').Trim('/')
    $entries = @(
        "hooks/$Executor/agent-audit.conf",
        "hooks/$Executor/agent-audit.ps1",
        "hooks/$Executor/lib/adapter.ps1",
        "hooks/$Executor/lib/agent-audit-core.ps1",
        "hooks/$Executor/lib/seal.ps1",
        "hooks/$Executor/recipient.pem",
        'requirements.toml'
    )
    foreach ($suffix in $entries) {
        $script:ProvenanceAbs.Add((Join-Path $ManagedRoot $suffix))
        $script:ProvenanceRel.Add("$rootRel/$suffix")
    }
    if ($env:USERPROFILE) {
        $script:ProvenanceAbs.Add((Join-Path $env:USERPROFILE '.codex\managed_config.toml'))
        $script:ProvenanceRel.Add('USERPROFILE/.codex/managed_config.toml')
    }
}

function ConvertFrom-Base64Url($Value) {
    $t = $Value.Replace('-', '+').Replace('_', '/')
    switch ($t.Length % 4) { 2 { $t += '==' } 3 { $t += '=' } }
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($t))
}

function Get-CodexProviderIdentity($CodexHome) {
    $r = [ordered]@{ account_id = $null; account_name = $null; account_email = $null; organization_id = $null; organization_name = $null }
    try {
        $authFile = Join-Path $CodexHome 'auth.json'
        if (-not (Test-Path -LiteralPath $authFile)) { return $r }
        $auth = [System.IO.File]::ReadAllText($authFile) | ConvertFrom-Json
        $r.account_id = $auth.tokens.account_id
        $idToken = $auth.tokens.id_token
        if ($idToken) {
            $parts = ([string]$idToken).Split('.')
            if ($parts.Length -ge 2) {
                $claims = ConvertFrom-Base64Url $parts[1] | ConvertFrom-Json
                $r.account_name = $claims.name
                $r.account_email = $claims.email
                $orgs = $claims.'https://api.openai.com/auth'.organizations
                if ($orgs) {
                    $org = $orgs | Where-Object { $_.is_default -eq $true } | Select-Object -First 1
                    if (-not $org) { $org = $orgs | Select-Object -First 1 }
                    if ($org) { $r.organization_id = $org.id; $r.organization_name = $org.title }
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
        organization = [ordered]@{ id = $ident.organization_id; name = $ident.organization_name }
    }
}
