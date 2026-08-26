$ErrorActionPreference = 'Stop'

# dot-source the edge sealing helper from this lib dir (defines Protect-Body)
$script:CoreLibDir = $PSScriptRoot
$sealLib = Join-Path $script:CoreLibDir 'seal.ps1'
if (Test-Path -LiteralPath $sealLib) { . $sealLib }

$DefaultTimeoutMs = 2000

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

function Get-Sha256Hex($Path) {
    try {
        $hasher = [System.Security.Cryptography.SHA256]::Create()
        try {
            $stream = [System.IO.File]::OpenRead($Path)
            try { $bytes = $hasher.ComputeHash($stream) } finally { $stream.Dispose() }
        }
        finally { $hasher.Dispose() }
        return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    }
    catch { return $null }
}

function Get-Sha256HexOfByteArray([byte[]]$Bytes) {
    try {
        $hasher = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = $hasher.ComputeHash($Bytes) } finally { $hasher.Dispose() }
        return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    }
    catch { return $null }
}

function Get-SingleVersionMatch($Dir) {
    try {
        $found = [System.IO.Directory]::GetFiles($Dir, '*.version')
        if ($found.Length -eq 1) { return $found[0] }
    }
    catch { return $null }
    return $null
}

# Locates the `.version`/`.sha256` sidecars `place`/`render` wrote beside this
# deployed cell (see sidecar_entries in agent-config/src/place.rs): one level
# up from the hook's own dir for local/project, two levels up (keyed by the
# hook dir's own name, which is the executor for managed) for managed.
function Resolve-ConfigProvenance {
    $script:ConfigVersion = $null
    $script:ConfigHash = $null
    $script:ConfigRuntimeHash = $null
    $script:ConfigIntegrity = 'unknown'

    try {
        $ownDir = Split-Path -Parent $script:CoreLibDir
        $ownName = Split-Path -Leaf $ownDir
        $parentDir = Split-Path -Parent $ownDir

        $layout = $null
        $versionFile = $null
        $hashFile = $null
        $homeDir = $null
        $targetRoot = $null
        $managedRoot = $null

        $localMatch = Get-SingleVersionMatch $parentDir
        if ($localMatch) {
            $layout = 'local'
            $versionFile = $localMatch
            $hashFile = [System.IO.Path]::ChangeExtension($localMatch, 'sha256')
            $homeDir = $parentDir
            $targetRoot = Split-Path -Parent $parentDir
        }
        else {
            $grandparentDir = Split-Path -Parent $parentDir
            $candidate = Join-Path $grandparentDir "$ownName.version"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $layout = 'managed'
                $versionFile = $candidate
                $hashFile = Join-Path $grandparentDir "$ownName.sha256"
                $managedRoot = $grandparentDir
            }
        }

        if (-not $layout) { return }
        if (-not (Test-Path -LiteralPath $hashFile -PathType Leaf)) { return }

        $script:ConfigVersion = ([System.IO.File]::ReadAllText($versionFile)).Trim()
        $script:ConfigHash = Get-Sha256Hex $hashFile

        $script:ProvenanceAbs = New-Object System.Collections.Generic.List[string]
        $script:ProvenanceRel = New-Object System.Collections.Generic.List[string]
        if ($layout -eq 'local') {
            Add-AuditProvenanceLocalManifest $homeDir $targetRoot
        }
        else {
            Add-AuditProvenanceManagedManifest $ownName $managedRoot
        }

        $existingAbs = New-Object System.Collections.Generic.List[string]
        $existingRel = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $script:ProvenanceAbs.Count; $i++) {
            if (Test-Path -LiteralPath $script:ProvenanceAbs[$i] -PathType Leaf) {
                $existingAbs.Add($script:ProvenanceAbs[$i])
                $existingRel.Add($script:ProvenanceRel[$i])
            }
        }
        if ($existingAbs.Count -eq 0) { return }

        # Ordinal (byte-wise) sort by rel path, matching Rust's `String::cmp`
        # — PowerShell's default Sort-Object is culture-aware and can reorder
        # punctuation differently.
        $relArr = $existingRel.ToArray()
        $absArr = $existingAbs.ToArray()
        [Array]::Sort($relArr, $absArr, [System.StringComparer]::Ordinal)

        $lines = for ($i = 0; $i -lt $relArr.Length; $i++) {
            $h = Get-Sha256Hex $absArr[$i]
            if (-not $h) { return }
            "$h  $($relArr[$i])"
        }
        $manifest = ($lines -join "`n") + "`n"
        $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifest)
        $script:ConfigRuntimeHash = Get-Sha256HexOfByteArray $manifestBytes

        if ($script:ConfigHash -and $script:ConfigRuntimeHash) {
            $script:ConfigIntegrity = if ($script:ConfigHash -eq $script:ConfigRuntimeHash) { 'match' } else { 'mismatch' }
        }
    }
    catch { Write-Verbose "fail-open: $_" }
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
        $cfg = @{}
        foreach ($line in Get-Content -LiteralPath $script:configFile) {
            if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
            $i = $line.IndexOf('=')
            $cfg[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim()
        }
        $script:enabled = $cfg["capture.$Stream.enabled"]
        $script:content = $cfg["capture.$Stream.content"]
        $script:esUrl = $cfg['elasticsearch.url']
        $script:apiKey = $cfg['elasticsearch.api_key']
        $timeoutMs = $cfg['elasticsearch.timeout_ms']
        $script:dataStream = $cfg["elasticsearch.data_stream.$Stream"]
        $script:sealRecipientsFile = $cfg['seal.recipients_file']
        $script:sealKeyId = $cfg['seal.key_id']
        $script:sealCompressMinBytes = $cfg['seal.compress_min_bytes']
        if ($script:content -eq 'encrypted' -and -not (Test-SealRecipient -RecipientsFile $script:sealRecipientsFile -Expected $script:sealKeyId)) {
            Log "recipient cert CN != seal.key_id ($script:sealKeyId) — metadata-only"
            $script:sealRecipientsFile = ''
        }
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
        try { [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { $null = $_ }
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
        Resolve-ConfigProvenance
        $config = [ordered]@{
            version      = $script:ConfigVersion
            hash         = $script:ConfigHash
            runtime_hash = $script:ConfigRuntimeHash
            integrity    = $script:ConfigIntegrity
        }
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
                    'encrypted' { '[ENCRYPTED]' }
                    default { $null }
                }
                $encField = $null
                $sealKid = $null
                if ($script:content -eq 'encrypted') {
                    $cmin = 0; if ($script:sealCompressMinBytes -match '^\d+$') { $cmin = [int]$script:sealCompressMinBytes }
                    $sealed = Protect-Body -RecipientsFile $script:sealRecipientsFile -CompressMinBytes $cmin -Body $script:promptText
                    if ($null -ne $sealed) { $encField = $sealed; $sealKid = $script:sealKeyId }
                    else { Log 'seal failed (user_prompt) — metadata-only' }
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
                        seal            = [ordered]@{ key_id = $sealKid }
                        config          = $config
                        user_prompt     = [ordered]@{ text = $promptField; encrypted_text = $encField; length = $script:promptLength }
                    }
                }
            }
            'tool_call' {
                $inputField = $null; $outputField = $null
                $inputEnc = $null; $outputEnc = $null; $sealKid = $null
                switch ($script:content) {
                    'plaintext' { $inputField = $script:inputText; $outputField = $script:outputText }
                    'redacted' {
                        if ($null -ne $script:inputText) { $inputField = '[REDACTED]' }
                        if ($null -ne $script:outputText) { $outputField = '[REDACTED]' }
                    }
                    'encrypted' {
                        $cmin = 0; if ($script:sealCompressMinBytes -match '^\d+$') { $cmin = [int]$script:sealCompressMinBytes }
                        if ($null -ne $script:inputText) {
                            $inputField = '[ENCRYPTED]'
                            $s = Protect-Body -RecipientsFile $script:sealRecipientsFile -CompressMinBytes $cmin -Body $script:inputText
                            if ($null -ne $s) { $inputEnc = $s; $sealKid = $script:sealKeyId } else { Log 'seal failed (tool_call input) — metadata-only' }
                        }
                        if ($null -ne $script:outputText) {
                            $outputField = '[ENCRYPTED]'
                            $s = Protect-Body -RecipientsFile $script:sealRecipientsFile -CompressMinBytes $cmin -Body $script:outputText
                            if ($null -ne $s) { $outputEnc = $s; $sealKid = $script:sealKeyId } else { Log 'seal failed (tool_call output) — metadata-only' }
                        }
                    }
                }
                $script:record = [ordered]@{
                    '@timestamp' = $identity.ts
                    event        = [ordered]@{ action = 'tool-call'; created = $identity.ts; dataset = 'agent_audit.tool_call'; kind = 'event' }
                    user         = $identity.user
                    host         = $identity.host
                    agent_audit  = [ordered]@{
                        agent           = $agent
                        conversation_id = $script:sessionId
                        turn_id         = $script:turnId
                        seal            = [ordered]@{ key_id = $sealKid }
                        config          = $config
                        tool_call       = [ordered]@{
                            tool   = [ordered]@{ name = $script:toolName; call_id = $script:callId }
                            input  = [ordered]@{ text = $inputField; encrypted_text = $inputEnc; length = $script:inputLength }
                            output = [ordered]@{ text = $outputField; encrypted_text = $outputEnc; length = $script:outputLength }
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
