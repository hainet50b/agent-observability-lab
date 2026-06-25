function Resolve-SealRecipient {
    param(
        [string]$RecipientsRoot,
        [string]$Epoch,
        [AllowEmptyString()][string]$Override = '',
        [AllowEmptyString()][string]$UpContent = '',
        [AllowEmptyString()][string]$TcContent = ''
    )
    $want = ($UpContent -eq 'encrypted') -or ($TcContent -eq 'encrypted')
    if ($want -and [string]::IsNullOrEmpty($Epoch)) {
        [Console]::Error.WriteLine('FAIL: content=encrypted requires agent_audit.seal.epoch')
        exit 2
    }
    if ([string]::IsNullOrEmpty($Epoch)) { return @('', '') }
    $src = if ($Override) { $Override } else { Join-Path $RecipientsRoot (Join-Path $Epoch 'recipient.pem') }
    if ($src -match '[\\/]private[\\/]') {
        [Console]::Error.WriteLine("FAIL: seal recipient must not be under sealing/private/: $src")
        exit 2
    }
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        [Console]::Error.WriteLine("FAIL: recipient cert not found for epoch $Epoch at $src")
        exit 2
    }
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new((Resolve-Path -LiteralPath $src).Path)
    $cn = if ($cert.Subject -match 'CN\s*=\s*agent-audit-recipient-([^,/]+)') { $Matches[1].Trim() } else { '' }
    if ($cn -ne $Epoch) {
        [Console]::Error.WriteLine("FAIL: recipient cert CN epoch $cn != seal.epoch $Epoch ($src)")
        exit 2
    }
    return @($src, $Epoch)
}
