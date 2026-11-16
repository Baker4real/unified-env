param([string]$ProjectRoot = (Split-Path -Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

# All keys and certificates are ephemeral. No cert store, installed package, network,
# or current wall clock is needed by this regression.
function New-FixtureCertificate {
    param([string]$Subject, $Issuer, [datetimeoffset]$NotBefore,
        [datetimeoffset]$NotAfter, [string]$Purpose)
    $key = [System.Security.Cryptography.RSA]::Create(2048)
    $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        $Subject, $key, [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new(
            ($null -eq $Issuer), $false, 0, $true))
    $usage = if ($null -eq $Issuer) {
        [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign
    } else { [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature }
    $request.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new($usage, $true))
    if ($Purpose) {
        $purposes = [System.Security.Cryptography.OidCollection]::new()
        [void]$purposes.Add([System.Security.Cryptography.Oid]::new($Purpose))
        $request.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($purposes, $true))
    }
    if ($null -eq $Issuer) { return $request.CreateSelfSigned($NotBefore, $NotAfter) }
    $serial = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16)
    $public = $request.Create($Issuer, $NotBefore, $NotAfter, $serial)
    try {
        return [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($public, $key)
    } finally { $public.Dispose(); $key.Dispose() }
}

function New-SignatureFixture {
    param($Certificate, $TimestampCertificate, [datetimeoffset]$Timestamp,
        [byte[]]$TimestampImprint = $null, [switch]$WithoutTimestamp, [switch]$TamperTimestamp)
    $content = [System.Security.Cryptography.Pkcs.ContentInfo]::new(
        [System.Security.Cryptography.Oid]::new('1.3.6.1.4.1.311.2.1.4'),
        [Text.Encoding]::UTF8.GetBytes('synthetic package signed content'))
    $cms = [System.Security.Cryptography.Pkcs.SignedCms]::new($content, $false)
    $cms.ComputeSignature([System.Security.Cryptography.Pkcs.CmsSigner]::new($Certificate))
    if (-not $WithoutTimestamp) {
        if ($null -eq $TimestampImprint) {
            $TimestampImprint = [System.Security.Cryptography.SHA256]::HashData($cms.SignerInfos[0].GetSignature())
        }
        $info = [System.Security.Cryptography.Pkcs.Rfc3161TimestampTokenInfo]::new(
            [System.Security.Cryptography.Oid]::new('1.2.3.4.1'),
            [System.Security.Cryptography.Oid]::new('2.16.840.1.101.3.4.2.1'),
            [ReadOnlyMemory[byte]]::new($TimestampImprint),
            [ReadOnlyMemory[byte]]::new([byte[]]@(1)), $Timestamp,
            $null, $false, $null, $null, $null)
        $tokenCms = [System.Security.Cryptography.Pkcs.SignedCms]::new(
            [System.Security.Cryptography.Pkcs.ContentInfo]::new(
                [System.Security.Cryptography.Oid]::new('1.2.840.113549.1.9.16.1.4'), $info.Encode()), $false)
        $tsaSigner = [System.Security.Cryptography.Pkcs.CmsSigner]::new($TimestampCertificate)
        # RFC 5816 SigningCertificateV2: SEQUENCE { SEQUENCE { SEQUENCE { OCTET STRING sha256 } } }.
        $certificateId = [byte[]](@(0x30, 0x26, 0x30, 0x24, 0x30, 0x22, 0x04, 0x20) +
            [System.Security.Cryptography.SHA256]::HashData($TimestampCertificate.RawData))
        [void]$tsaSigner.SignedAttributes.Add([System.Security.Cryptography.AsnEncodedData]::new(
            [System.Security.Cryptography.Oid]::new('1.2.840.113549.1.9.16.2.47'), $certificateId))
        $tokenCms.ComputeSignature($tsaSigner)
        $tokenBytes = $tokenCms.Encode()
        if ($TamperTimestamp) { $tokenBytes[-1] = $tokenBytes[-1] -bxor 1 }
        $cms.SignerInfos[0].AddUnsignedAttribute([System.Security.Cryptography.AsnEncodedData]::new(
            [System.Security.Cryptography.Oid]::new('1.3.6.1.4.1.311.3.3.1'), $tokenBytes))
    }
    return ,([byte[]]([Text.Encoding]::ASCII.GetBytes('PKCX') + $cms.Encode()))
}

function Copy-Evidence {
    param([hashtable]$Changes = @{})
    $copy = $evidence.PSObject.Copy()
    foreach ($key in $Changes.Keys) { $copy.$key = $Changes[$key] }
    return $copy
}

function Assert-Rejected {
    param([string]$Label, [psobject]$InputEvidence, [string]$Reason,
        [string]$Channel = 'PrimaryRuntime',
        [System.Security.Cryptography.X509Certificates.X509Certificate2[]]$Roots = @($root),
        [datetimeoffset]$AtTime = '2030-01-10Z')
    $caught = $null
    try {
        & $entry -Channel $Channel -Evidence $InputEvidence -TrustRoot $Roots -VerificationTime $AtTime | Out-Null
    } catch { $caught = $_.Exception.Message }
    Assert-True ($null -ne $caught -and $caught.Contains($Reason)) "$Label must fail with $Reason; actual=$caught"
    $script:passed++
    Write-Output "PASS $Label"
}

$passed = 0
$root = New-FixtureCertificate -Subject 'CN=Ephemeral fixture root' -NotBefore '2020-01-01Z' -NotAfter '2040-01-01Z'
$publisher = 'CN="OpenAI OpCo, LLC", O="OpenAI OpCo, LLC", L=San Francisco, S=California, C=US'
$code = New-FixtureCertificate -Subject $publisher -Issuer $root -NotBefore '2030-01-01Z' -NotAfter '2030-01-06Z' -Purpose '1.3.6.1.5.5.7.3.3'
$tsa = New-FixtureCertificate -Subject 'CN=Ephemeral fixture TSA' -Issuer $root -NotBefore '2029-01-01Z' -NotAfter '2031-01-01Z' -Purpose '1.3.6.1.5.5.7.3.8'
$signature = New-SignatureFixture -Certificate $code -TimestampCertificate $tsa -Timestamp '2030-01-04Z'
$entry = Join-Path $ProjectRoot 'scripts/Test-OfficialPackageSignature.ps1'
$evidence = [pscustomobject]@{
    Name = 'OpenAI.CodexPrimaryRuntime.v26-1112-737-0'
    Publisher = $publisher
    SignatureKind = 'Developer'
    Status = 'Ok'
    SignatureBytes = $signature
}
try {
    $result = & $entry -Channel PrimaryRuntime -Evidence $evidence -TrustRoot $root -VerificationTime '2030-01-10Z'
    Assert-True ($result.verified -and $result.timestamp_binding_verified -and
        $result.signer_chain_valid -and $result.timestamp_chain_valid -and
        $result.certificate_expired_now -and $result.evidence_source -eq 'supplied-evidence') `
        'Expired primary-runtime signer must be accepted only through its bound, trusted timestamp.'
    $passed++
    Write-Output 'PASS expired primary-runtime certificate with trusted bound RFC3161 timestamp'

    Assert-Rejected 'identity fields cannot be arrays' (Copy-Evidence @{ Name = @($evidence.Name) }) 'invalid-evidence-field:Name'
    Assert-Rejected 'primary runtime cannot use the Store channel' $evidence 'channel-identity-mismatch' -Channel StoreMain
    Assert-Rejected 'primary runtime cannot claim SignatureKind Store' (Copy-Evidence @{ SignatureKind = 'Store' }) 'channel-identity-mismatch'
    Assert-Rejected 'primary runtime rejects non-versioned or suffix names' (Copy-Evidence @{ Name = 'OpenAI.CodexPrimaryRuntime.v26-1112-737-0.evil' }) 'channel-identity-mismatch'
    Assert-Rejected 'wrong metadata publisher' (Copy-Evidence @{ Publisher = 'CN=Other Publisher' }) 'publisher-identity-mismatch'
    Assert-Rejected 'non-Ok Appx status' (Copy-Evidence @{ Status = 'Modified' }) 'appx-status-not-ok'
    Assert-Rejected 'signature envelope missing PKCX' (Copy-Evidence @{ SignatureBytes = [byte[]]$signature[4..($signature.Length - 1)] }) 'invalid-pkcx-prefix'

    # Change a byte of the signed content while preserving the signature and ASN.1 shape.
    $damaged = [byte[]]$signature.Clone()
    $contentIndex = [Text.Encoding]::ASCII.GetString($damaged).IndexOf('synthetic package signed content', [StringComparison]::Ordinal)
    Assert-True ($contentIndex -ge 0) 'Fixture must expose the signed payload for the tamper negative control.'
    $damaged[$contentIndex] = $damaged[$contentIndex] -bxor 1
    Assert-Rejected 'cryptographically damaged package signature' (Copy-Evidence @{ SignatureBytes = $damaged }) 'cms-signature-invalid'

    $noTimestamp = New-SignatureFixture -Certificate $code -WithoutTimestamp
    Assert-Rejected 'expired signer without RFC3161 timestamp' (Copy-Evidence @{ SignatureBytes = $noTimestamp }) 'one-rfc3161-timestamp-required'
    $unbound = New-SignatureFixture -Certificate $code -TimestampCertificate $tsa -Timestamp '2030-01-04Z' -TimestampImprint ([byte[]]::new(32))
    Assert-Rejected 'valid TSA signature bound to another imprint' (Copy-Evidence @{ SignatureBytes = $unbound }) 'timestamp-signature-or-binding-invalid'
    $tamperedTimestamp = New-SignatureFixture -Certificate $code -TimestampCertificate $tsa -Timestamp '2030-01-04Z' -TamperTimestamp
    Assert-Rejected 'damaged TSA signature with correct imprint' (Copy-Evidence @{ SignatureBytes = $tamperedTimestamp }) 'timestamp-'
    Assert-Rejected 'untrusted signing and TSA chains' $evidence 'timestamp-chain-invalid' -Roots @()

    $otherRoot = New-FixtureCertificate -Subject 'CN=Untrusted fixture root' -NotBefore '2020-01-01Z' -NotAfter '2040-01-01Z'
    $otherSigner = New-FixtureCertificate -Subject $publisher -Issuer $otherRoot -NotBefore '2030-01-01Z' -NotAfter '2030-01-06Z' -Purpose '1.3.6.1.5.5.7.3.3'
    $otherTsa = New-FixtureCertificate -Subject 'CN=Untrusted fixture TSA' -Issuer $otherRoot -NotBefore '2029-01-01Z' -NotAfter '2031-01-01Z' -Purpose '1.3.6.1.5.5.7.3.8'
    $wrongPurpose = New-FixtureCertificate -Subject $publisher -Issuer $root -NotBefore '2030-01-01Z' -NotAfter '2030-01-06Z' -Purpose '1.3.6.1.5.5.7.3.8'
    try {
        $untrustedSigner = New-SignatureFixture -Certificate $otherSigner -TimestampCertificate $tsa -Timestamp '2030-01-04Z'
        Assert-Rejected 'trusted timestamp cannot rescue untrusted publisher chain' (Copy-Evidence @{ SignatureBytes = $untrustedSigner }) 'signer-chain-invalid'
        $untrustedTsa = New-SignatureFixture -Certificate $code -TimestampCertificate $otherTsa -Timestamp '2030-01-04Z'
        Assert-Rejected 'trusted publisher cannot rescue untrusted timestamp chain' (Copy-Evidence @{ SignatureBytes = $untrustedTsa }) 'timestamp-chain-invalid'
        $wrongCodePurpose = New-SignatureFixture -Certificate $wrongPurpose -TimestampCertificate $tsa -Timestamp '2030-01-04Z'
        Assert-Rejected 'publisher certificate must allow code signing' (Copy-Evidence @{ SignatureBytes = $wrongCodePurpose }) 'signer-chain-invalid'
        $wrongTsaPurpose = New-SignatureFixture -Certificate $code -TimestampCertificate $code -Timestamp '2030-01-04Z'
        Assert-Rejected 'timestamp certificate must allow timestamping' (Copy-Evidence @{ SignatureBytes = $wrongTsaPurpose }) 'timestamp-'
    } finally {
        $otherSigner.Dispose(); $otherTsa.Dispose(); $wrongPurpose.Dispose(); $otherRoot.Dispose()
    }
    Assert-Rejected 'timestamp later than trusted verification clock' $evidence 'timestamp-in-future' -AtTime '2030-01-03Z'

    $tooEarly = New-SignatureFixture -Certificate $code -TimestampCertificate $tsa -Timestamp '2029-12-31T23:59:59Z'
    Assert-Rejected 'timestamp before publisher certificate validity' (Copy-Evidence @{ SignatureBytes = $tooEarly }) 'signer-chain-invalid'
    $tooLate = New-SignatureFixture -Certificate $code -TimestampCertificate $tsa -Timestamp '2030-01-06T00:00:01Z'
    Assert-Rejected 'timestamp after publisher certificate validity' (Copy-Evidence @{ SignatureBytes = $tooLate }) 'signer-chain-invalid'

    foreach ($boundary in @('2030-01-01T00:00:00Z', '2030-01-06T00:00:00Z')) {
        $boundarySignature = New-SignatureFixture -Certificate $code -TimestampCertificate $tsa -Timestamp $boundary
        $boundaryResult = & $entry -Channel PrimaryRuntime -Evidence (Copy-Evidence @{ SignatureBytes = $boundarySignature }) -TrustRoot $root -VerificationTime '2030-01-10Z'
        Assert-True $boundaryResult.verified "Valid certificate boundary must be inclusive: $boundary"
        $passed++
        Write-Output "PASS inclusive publisher certificate boundary $boundary"
    }

    $storeCode = New-FixtureCertificate -Subject 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B' -Issuer $root -NotBefore '2030-01-01Z' -NotAfter '2030-01-06Z' -Purpose '1.3.6.1.5.5.7.3.3'
    try {
        $storeEvidence = Copy-Evidence @{
            Name = 'OpenAI.Codex'
            Publisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
            SignatureKind = 'Store'
            SignatureBytes = (New-SignatureFixture -Certificate $storeCode -TimestampCertificate $tsa -Timestamp '2030-01-04Z')
        }
        $storeResult = & $entry -Channel StoreMain -Evidence $storeEvidence -TrustRoot $root -VerificationTime '2030-01-10Z' -AsJson | ConvertFrom-Json
        Assert-True (@($storeResult).Count -eq 1 -and $storeResult[0].verified -and
            $storeResult[0].channel -eq 'StoreMain') 'Official Store identity must verify through the public JSON interface.'
        $passed++
        Write-Output 'PASS Store main with its fixed publisher and bound timestamp'
        $developerStore = $storeEvidence.PSObject.Copy()
        $developerStore.SignatureKind = 'Developer'
        Assert-Rejected 'Store main cannot downgrade to Developer' $developerStore 'channel-identity-mismatch' -Channel StoreMain
        Assert-Rejected 'Store main cannot use primary-runtime channel' $storeEvidence 'channel-identity-mismatch'
        # Metadata alone must not impersonate the Store GUID publisher.
        $forgedStore = $storeEvidence.PSObject.Copy()
        $forgedStore.SignatureBytes = $signature
        Assert-Rejected 'signer certificate differs from accepted metadata publisher' $forgedStore 'signer-publisher-mismatch' -Channel StoreMain
    } finally { $storeCode.Dispose() }

    Write-Output "PASS OfficialPackageSignature regression: $passed checks; offline ephemeral certificates; no live package required"
} finally {
    $code.Dispose(); $tsa.Dispose(); $root.Dispose()
}
