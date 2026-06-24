# seal.ps1 - edge content-sealing helper (dot-sourced by agent-audit-core.ps1).
# Protect-Body -RecipientsFile <path> [-CompressMinBytes <int>] [-Body <string>]:
# body -> single-line base64(DER CMS), or $null on any failure (caller -> metadata-only).
# Mirrors seal.sh; no [Mandatory] so a missing param fails soft to $null, never throws.
# Uses .NET EnvelopedCms (System.Security; stock Windows incl. PS 5.1), not Protect-CmsMessage.

function Protect-Body {
    param(
        [string]$RecipientsFile,
        [int]$CompressMinBytes = 0,
        [AllowEmptyString()][string]$Body = ''
    )
    try {
        if ([string]::IsNullOrEmpty($RecipientsFile) -or -not (Test-Path -LiteralPath $RecipientsFile)) { return $null }
        Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue

        $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Body)
        if ($CompressMinBytes -gt 0 -and $bodyBytes.Length -ge $CompressMinBytes) {
            $tag = 1
            $ms = [IO.MemoryStream]::new()
            $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress)
            $gz.Write($bodyBytes, 0, $bodyBytes.Length)
            $gz.Dispose()
            $payload = $ms.ToArray()
        }
        else {
            $tag = 0
            $payload = $bodyBytes
        }
        $framed = [byte[]]([byte[]]@($tag) + $payload)

        $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($RecipientsFile)
        $ci = [Security.Cryptography.Pkcs.ContentInfo]::new($framed)
        $algo = [Security.Cryptography.Pkcs.AlgorithmIdentifier]::new(
            [Security.Cryptography.Oid]::new('2.16.840.1.101.3.4.1.42')) # AES-256-CBC
        $env = [Security.Cryptography.Pkcs.EnvelopedCms]::new($ci, $algo)
        $env.Encrypt([Security.Cryptography.Pkcs.CmsRecipient]::new($cert))
        return [Convert]::ToBase64String($env.Encode())
    }
    catch {
        return $null
    }
}
