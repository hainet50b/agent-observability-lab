$ErrorActionPreference = 'Stop'

$DefaultTimeoutMs = 1000

function Log($Message) {
    [Console]::Error.WriteLine("[agent-audit $script:Stream] $Message")
}

function NullIfEmpty($Value) {
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    return [string]$Value
}

function ConvertTo-JsonText($Value) {
    if ($null -eq $Value) { return $null }
    return ($Value | ConvertTo-Json -Compress -Depth 50)
}

function Measure-CodePoint($Value) {
    if ($null -eq $Value) { return 0 }
    $s = [string]$Value
    $count = 0
    foreach ($c in $s.ToCharArray()) {
        if (-not [System.Char]::IsLowSurrogate($c)) { $count++ }
    }
    return $count
}

function Assert-Stream($Stream) {
    if ($Stream -ne 'user_prompt' -and $Stream -ne 'tool_call') {
        Log 'no valid -Stream <user_prompt|tool_call> provided — skipping'; exit 0
    }
}

function Assert-Config($Config) {
    if (-not $Config) {
        Log 'no -Config <path> provided — skipping'; exit 0
    }
    $script:configFile = $Config
    if (-not (Test-Path -LiteralPath $script:configFile)) {
        Log "no delivery config at $script:configFile — skipping"; exit 0
    }
}

function Import-DeliveryConfig($Stream) {
    try {
        $cfg = Get-Content -Raw -LiteralPath $script:configFile | ConvertFrom-StringData
        $script:enabled = $cfg["capture.$Stream.enabled"]
        $script:content = $cfg["capture.$Stream.content"]
        $script:esUrl = $cfg['elasticsearch.url']
        $script:apiKey = $cfg['elasticsearch.api_key']
        $timeoutMs = $cfg['elasticsearch.timeout_ms']
        $script:dataStream = $cfg["elasticsearch.data_stream.$Stream"]
        if (-not $script:esUrl -or -not $script:dataStream) {
            Log "config missing elasticsearch.url / data_stream.$Stream — skipping"; exit 0
        }
        $script:timeoutSec = $DefaultTimeoutMs / 1000.0
        if ($timeoutMs -match '^\d+$') { $script:timeoutSec = [int]$timeoutMs / 1000.0 }
    }
    catch { Log "config load failed ($_) — skipping"; exit 0 }
}

function Assert-StreamEnabled($Stream) {
    if ($script:enabled -eq 'false') {
        Log "capture.$Stream.enabled=false — skipping (stream disabled)"; exit 0
    }
}

function Read-HookPayload($Stream) {
    try {
        try { [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}
        $raw = [Console]::In.ReadToEnd()
        if (-not $raw) { Log 'empty stdin — nothing to capture'; exit 0 }
        try { $script:rawObj = $raw | ConvertFrom-Json }
        catch { Log 'payload not valid JSON — cannot shape audit document; skipping'; exit 0 }
        switch ($Stream) {
            'user_prompt' {
                $script:promptText = [string]$script:rawObj.prompt
                if (-not $script:promptText) { Log 'no prompt in payload — nothing to capture'; exit 0 }
                $script:promptLength = Measure-CodePoint $script:promptText
                $script:sessionId = NullIfEmpty $script:rawObj.session_id
                $script:turnId = NullIfEmpty $script:rawObj.turn_id
            }
            'tool_call' {
                $script:toolName = $script:rawObj.tool_name
                $script:callId = $script:rawObj.tool_use_id
                $script:sessionId = NullIfEmpty $script:rawObj.session_id
                $script:turnId = NullIfEmpty $script:rawObj.turn_id
                $script:inputText = ConvertTo-JsonText $script:rawObj.tool_input
                $script:outputText = ConvertTo-JsonText $script:rawObj.tool_response
                $script:inputLength = if ($null -ne $script:inputText) { Measure-CodePoint $script:inputText } else { 0 }
                $script:outputLength = if ($null -ne $script:outputText) { Measure-CodePoint $script:outputText } else { 0 }
            }
            default { Log "unknown stream '$Stream' — skipping"; exit 0 }
        }
    }
    catch { Log "read payload failed ($_) — session proceeds uncaptured"; exit 0 }
}

function Build-AuditDocument($Stream) {
    try {
        $identity = Get-RuntimeIdentity
        $agent = [ordered]@{
            provider     = $script:Provider
            name         = $script:AgentName
            account      = $identity.account
            organization = $identity.organization
        }
        switch ($Stream) {
            'user_prompt' {
                $promptField = switch ($script:content) {
                    'plaintext' { $script:promptText }
                    'redacted' { '[REDACTED]' }
                    default { $null }
                }
                $script:record = [ordered]@{
                    '@timestamp' = $identity.ts
                    event        = [ordered]@{ action = 'user-prompt'; created = $identity.ts; dataset = 'agent_audit.user_prompt'; kind = 'event' }
                    user         = $identity.user
                    host         = $identity.host
                    agent_audit  = [ordered]@{
                        agent           = $agent
                        conversation_id = $script:sessionId
                        turn_id         = $script:turnId
                        user_prompt     = [ordered]@{ text = $promptField; encrypted_text = $null; length = $script:promptLength }
                    }
                }
            }
            'tool_call' {
                $inputField = if ($script:content -eq 'plaintext') { $script:inputText }
                elseif ($script:content -eq 'redacted' -and $null -ne $script:inputText) { '[REDACTED]' }
                else { $null }
                $outputField = if ($script:content -eq 'plaintext') { $script:outputText }
                elseif ($script:content -eq 'redacted' -and $null -ne $script:outputText) { '[REDACTED]' }
                else { $null }
                $script:record = [ordered]@{
                    '@timestamp' = $identity.ts
                    event        = [ordered]@{ action = 'tool-call'; created = $identity.ts; dataset = 'agent_audit.tool_call'; kind = 'event' }
                    user         = $identity.user
                    host         = $identity.host
                    agent_audit  = [ordered]@{
                        agent           = $agent
                        conversation_id = $script:sessionId
                        turn_id         = $script:turnId
                        tool_call       = [ordered]@{
                            tool   = [ordered]@{ name = $script:toolName; call_id = $script:callId }
                            input  = [ordered]@{ text = $inputField; encrypted_text = $null; length = $script:inputLength }
                            output = [ordered]@{ text = $outputField; encrypted_text = $null; length = $script:outputLength }
                        }
                    }
                }
            }
            default { Log "unknown stream '$Stream' — skipping"; exit 0 }
        }
    }
    catch { Log "build failed ($_) — session proceeds uncaptured"; exit 0 }
}

function Send-Document {
    try {
        $json = $script:record | ConvertTo-Json -Compress -Depth 50
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $esBase = ($script:esUrl.TrimEnd('/')) -replace '://localhost([:/]|$)', '://127.0.0.1$1'
        $esTarget = $esBase + '/' + $script:dataStream + '/_doc'
        $headers = @{ 'Content-Type' = 'application/json' }
        if ($script:apiKey) { $headers['Authorization'] = "ApiKey $script:apiKey" }
        try {
            Invoke-RestMethod -Method Post -Uri $esTarget -Headers $headers `
                -Body $bytes -TimeoutSec $script:timeoutSec | Out-Null
            Log "indexed 1 audit document -> $esTarget"
        }
        catch {
            Log "POST to $esTarget failed ($_) — session proceeds uncaptured"
        }
    }
    catch { Log "deliver failed ($_) — session proceeds uncaptured" }
    exit 0
}
