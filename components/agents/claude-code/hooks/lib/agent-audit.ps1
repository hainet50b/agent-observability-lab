$ErrorActionPreference = 'Stop'

function Log($m) {
    $tag = if ($stream -eq 'tool_call') { 'capture-tool-call' } else { 'capture-user-prompt' }
    [Console]::Error.WriteLine("[$tag] $m")
}

function NullIfEmpty($v) { if ([string]::IsNullOrWhiteSpace([string]$v)) { return $null } return [string]$v }

function ConvertTo-JsonText($value) {
    if ($null -eq $value) { return $null }
    return ($value | ConvertTo-Json -Compress -Depth 50)
}

function Assert-ConfigArg($argList) {
    $script:configFile = $null
    for ($i = 0; $i -lt $argList.Count; $i++) {
        if (($argList[$i] -eq '-Config' -or $argList[$i] -eq '--config') -and $i + 1 -lt $argList.Count) {
            $script:configFile = $argList[$i + 1]
        }
    }
    if (-not $configFile) {
        Log 'no -Config <path> provided — skipping (the rendered hook command injects it)'; exit 0
    }
}

function Import-DeliveryConfig {
    try {
        if (-not (Test-Path -LiteralPath $configFile)) {
            Log "no delivery config at $configFile — skipping (run setup.ps1)"; exit 0
        }
        $cfg = Get-Content -Raw -LiteralPath $configFile | ConvertFrom-StringData
        $script:enabled = $cfg["capture.$stream.enabled"]
        $script:content = $cfg["capture.$stream.content"]
        $script:esUrl = $cfg['elasticsearch.url']
        $script:apiKey = $cfg['elasticsearch.api_key']
        $timeoutMs = $cfg['elasticsearch.timeout_ms']
        $script:dataStream = $cfg["elasticsearch.data_stream.$stream"]
        if (-not $esUrl -or -not $dataStream) {
            Log "config missing elasticsearch.url / data_stream.$stream — skipping"; exit 0
        }
        $script:timeoutSec = 0.3
        if ($timeoutMs -match '^\d+$') { $script:timeoutSec = [int]$timeoutMs / 1000.0 }
    }
    catch { Log "config load failed ($_) — skipping"; exit 0 }
}

function Assert-StreamEnabled {
    if ($enabled -eq 'false') {
        Log "capture.$stream.enabled=false — skipping (stream disabled)"; exit 0
    }
}

function Read-HookPayload {
    try {
        $raw = [Console]::In.ReadToEnd()
        if (-not $raw) { Log 'empty stdin — nothing to capture'; exit 0 }
        try { $script:rawObj = $raw | ConvertFrom-Json }
        catch { Log 'payload not valid JSON — cannot shape audit document; skipping'; exit 0 }
        if ($stream -eq 'user_prompt') {
            $script:prompt = [string]$rawObj.prompt
            if (-not $prompt) { Log 'no prompt in payload — nothing to capture'; exit 0 }
            $script:promptLen = $prompt.Length
        }
        else {
            $script:inText = ConvertTo-JsonText $rawObj.tool_input
            $script:outText = ConvertTo-JsonText $rawObj.tool_response
            $script:inLen = if ($null -ne $inText) { ([string]$inText).Length } else { 0 }
            $script:outLen = if ($null -ne $outText) { ([string]$outText).Length } else { 0 }
        }
    }
    catch { Log "read payload failed ($_) — session proceeds uncaptured"; exit 0 }
}

function Build-AuditDocument {
    try {
        $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

        $userName = if ($env:USER) { $env:USER } elseif ($env:USERNAME) { $env:USERNAME } else { [Environment]::UserName }
        $userName = NullIfEmpty $userName
        $userId = try { ([string](& whoami) 2>$null).Trim() } catch { $null }
        $userId = NullIfEmpty $userId

        $hostName = NullIfEmpty ([System.Net.Dns]::GetHostName())

        $claudeConfig = if ($env:CLAUDE_CONFIG) { $env:CLAUDE_CONFIG } else { Join-Path $HOME '.claude.json' }
        $acctId = $null; $acctName = $null; $acctEmail = $null; $orgId = $null; $orgName = $null
        if (Test-Path -LiteralPath $claudeConfig -PathType Leaf) {
            try {
                $oauth = (Get-Content -Raw -LiteralPath $claudeConfig | ConvertFrom-Json).oauthAccount
                if ($oauth) {
                    $acctId = NullIfEmpty $oauth.accountUuid
                    $acctName = NullIfEmpty $oauth.displayName
                    $acctEmail = NullIfEmpty $oauth.emailAddress
                    $orgId = NullIfEmpty $oauth.organizationUuid
                    $orgName = NullIfEmpty $oauth.organizationName
                }
            }
            catch { Write-Verbose "fail-open: $_" }
        }

        $agent = [ordered]@{
            provider     = 'anthropic'
            name         = 'claude-code'
            account      = [ordered]@{ id = $acctId; name = $acctName; email = $acctEmail }
            organization = [ordered]@{ id = $orgId; name = $orgName }
        }

        if ($stream -eq 'user_prompt') {
            $textField = switch ($content) {
                'plaintext' { $prompt }
                'redacted' { '[REDACTED]' }
                default { $null }
            }
            $script:record = [ordered]@{
                '@timestamp' = $ts
                event        = [ordered]@{ action = 'user-prompt'; created = $ts; dataset = 'agent_audit.user_prompt'; kind = 'event' }
                user         = [ordered]@{ id = $userId; name = $userName }
                host         = [ordered]@{ name = $hostName; hostname = $hostName }
                agent_audit  = [ordered]@{
                    agent           = $agent
                    conversation_id = (NullIfEmpty $rawObj.session_id)
                    turn_id         = $null
                    user_prompt     = [ordered]@{ text = $textField; encrypted_text = $null; length = $promptLen }
                }
            }
        }
        else {
            $inTextField = if ($content -eq 'plaintext') { $inText }
            elseif ($content -eq 'redacted' -and $null -ne $inText) { '[REDACTED]' }
            else { $null }
            $outTextField = if ($content -eq 'plaintext') { $outText }
            elseif ($content -eq 'redacted' -and $null -ne $outText) { '[REDACTED]' }
            else { $null }
            $script:record = [ordered]@{
                '@timestamp' = $ts
                event        = [ordered]@{ action = 'tool-call'; created = $ts; dataset = 'agent_audit.tool_call'; kind = 'event' }
                user         = [ordered]@{ id = $userId; name = $userName }
                host         = [ordered]@{ name = $hostName; hostname = $hostName }
                agent_audit  = [ordered]@{
                    agent           = $agent
                    conversation_id = (NullIfEmpty $rawObj.session_id)
                    turn_id         = (NullIfEmpty $rawObj.turn_id)
                    tool_call       = [ordered]@{
                        tool   = [ordered]@{ name = $rawObj.tool_name; call_id = $rawObj.tool_use_id }
                        input  = [ordered]@{ text = $inTextField; encrypted_text = $null; length = $inLen }
                        output = [ordered]@{ text = $outTextField; encrypted_text = $null; length = $outLen }
                    }
                }
            }
        }
    }
    catch { Log "build failed ($_) — session proceeds uncaptured"; exit 0 }
}

function Send-Document {
    try {
        $json = $record | ConvertTo-Json -Compress -Depth 50
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $esBase = ($esUrl.TrimEnd('/')) -replace '://localhost([:/]|$)', '://127.0.0.1$1'
        $esTarget = $esBase + '/' + $dataStream + '/_doc'
        $headers = @{ 'Content-Type' = 'application/json' }
        if ($apiKey) { $headers['Authorization'] = "ApiKey $apiKey" }
        try {
            Invoke-RestMethod -Method Post -Uri $esTarget -Headers $headers `
                -Body $bytes -TimeoutSec $timeoutSec | Out-Null
            Log "indexed 1 audit document -> $esTarget"
        }
        catch {
            Log "POST to $esTarget failed ($_) — session proceeds uncaptured"
        }
    }
    catch { Log "deliver failed ($_) — session proceeds uncaptured" }
    exit 0
}
