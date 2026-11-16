Set-StrictMode -Version Latest

function Assert-OfficialSignatureChain {
    param(
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]$ExtraCertificates,
        [System.Security.Cryptography.X509Certificates.X509Certificate2[]]$TrustRoot,
        [datetimeoffset]$AtTime,
        [string]$Purpose,
        [string]$Role
    )
    $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        $chain.ChainPolicy.VerificationTime = $AtTime.UtcDateTime
        $chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
        # This read-only, offline check neither fetches certificates/CRLs nor writes trust stores.
        # Revocation is deliberately reported as not checked; this is not a revocation verdict.
        $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $chain.ChainPolicy.DisableCertificateDownloads = $true
        [void]$chain.ChainPolicy.ApplicationPolicy.Add([System.Security.Cryptography.Oid]::new($Purpose))
        $chain.ChainPolicy.ExtraStore.AddRange($ExtraCertificates)
        if ($TrustRoot.Count -gt 0) {
            $chain.ChainPolicy.TrustMode = [System.Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
            $chain.ChainPolicy.CustomTrustStore.AddRange($TrustRoot)
        }
        if (-not $chain.Build($Certificate)) {
            $statuses = @($chain.ChainStatus | ForEach-Object { $_.Status.ToString() }) -join ','
            throw "${Role}-chain-invalid:$statuses"
        }
    } finally { $chain.Dispose() }
}

function Test-OfficialPackageSignatureEvidence {
    <#
    .SYNOPSIS
    Verifies supplied Appx identity metadata and PKCX/CMS signature evidence, without installing anything.
    .DESCRIPTION
    This public seam accepts caller-supplied evidence, not an independently authenticated Appx registration.
    TrustRoot and VerificationTime permit offline, ephemeral cryptographic fixtures. The installed-package
    entry point never exposes these overrides. CMS authenticity and timestamp binding are checked here;
    this is not a package payload/block-map digest or revocation verifier.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('StoreMain', 'PrimaryRuntime')][string]$Channel,
        [Parameter(Mandatory)][psobject]$Evidence,
        [System.Security.Cryptography.X509Certificates.X509Certificate2[]]$TrustRoot = @(),
        [datetimeoffset]$VerificationTime = [datetimeoffset]::UtcNow
    )
    $ErrorActionPreference = 'Stop'
    $storePublisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
    $runtimePublisher = 'CN="OpenAI OpCo, LLC", O="OpenAI OpCo, LLC", L=San Francisco, S=California, C=US'
    foreach ($field in @('Name', 'Publisher', 'SignatureKind', 'Status', 'SignatureBytes')) {
        if ($null -eq $Evidence.PSObject.Properties[$field] -or $null -eq $Evidence.$field) {
            throw "missing-evidence-field:$field"
        }
    }
    foreach ($field in @('Name', 'Publisher', 'SignatureKind', 'Status')) {
        if ($Evidence.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($Evidence.$field)) {
            throw "invalid-evidence-field:$field"
        }
    }
    if ($Channel -eq 'StoreMain') {
        if ($Evidence.Name -cne 'OpenAI.Codex' -or $Evidence.SignatureKind -cne 'Store') {
            throw 'channel-identity-mismatch:StoreMain'
        }
        $expectedPublisher = $storePublisher
    } else {
        if ($Evidence.Name -cnotmatch '^OpenAI[.]CodexPrimaryRuntime[.]v[0-9]+(?:-[0-9]+){3}$' -or
            $Evidence.SignatureKind -cne 'Developer') {
            throw 'channel-identity-mismatch:PrimaryRuntime'
        }
        $expectedPublisher = $runtimePublisher
    }
    if ($Evidence.Publisher -cne $expectedPublisher) { throw 'publisher-identity-mismatch' }
    if ($Evidence.Status -cne 'Ok') { throw 'appx-status-not-ok' }
    if ($Evidence.SignatureBytes -isnot [byte[]]) { throw 'signature-bytes-required' }
    $bytes = $Evidence.SignatureBytes
    if ($bytes.Length -le 4 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'PKCX') {
        throw 'invalid-pkcx-prefix'
    }
    $cms = [System.Security.Cryptography.Pkcs.SignedCms]::new()
    try {
        $cms.Decode([byte[]]$bytes[4..($bytes.Length - 1)])
        $cms.CheckSignature($true)
    } catch { throw 'cms-signature-invalid' }
    if ($cms.Detached -or $cms.ContentInfo.ContentType.Value -cne '1.3.6.1.4.1.311.2.1.4' -or
        $cms.SignerInfos.Count -ne 1) { throw 'unsupported-package-cms-shape' }
    $signer = $cms.SignerInfos[0]
    if ($null -eq $signer.Certificate -or $signer.Certificate.Subject -cne $expectedPublisher) {
        throw 'signer-publisher-mismatch'
    }
    $timestamps = @($signer.UnsignedAttributes | Where-Object { $_.Oid.Value -ceq '1.3.6.1.4.1.311.3.3.1' })
    if ($timestamps.Count -ne 1 -or $timestamps[0].Values.Count -ne 1) {
        throw 'one-rfc3161-timestamp-required'
    }
    $encodedToken = $timestamps[0].Values[0].RawData
    $token = $null
    $consumed = 0
    if (-not [System.Security.Cryptography.Pkcs.Rfc3161TimestampToken]::TryDecode(
        [ReadOnlyMemory[byte]]::new($encodedToken), [ref]$token, [ref]$consumed) -or
        $consumed -ne $encodedToken.Length) { throw 'timestamp-token-invalid' }
    $tsaCertificate = $null
    if (-not $token.VerifySignatureForSignerInfo($signer, [ref]$tsaCertificate, $cms.Certificates)) {
        throw 'timestamp-signature-or-binding-invalid'
    }
    $timestamp = $token.TokenInfo.Timestamp
    if ($timestamp -gt $VerificationTime) { throw 'timestamp-in-future' }
    $timestampCertificates = $token.AsSignedCms().Certificates
    Assert-OfficialSignatureChain -Certificate $tsaCertificate -ExtraCertificates $timestampCertificates `
        -TrustRoot $TrustRoot -AtTime $timestamp -Purpose '1.3.6.1.5.5.7.3.8' -Role timestamp
    Assert-OfficialSignatureChain -Certificate $signer.Certificate -ExtraCertificates $cms.Certificates `
        -TrustRoot $TrustRoot -AtTime $timestamp -Purpose '1.3.6.1.5.5.7.3.3' -Role signer
    [pscustomobject]@{
        schema_version = 1
        verified = $true
        channel = $Channel
        package_name = [string]$Evidence.Name
        signature_kind = [string]$Evidence.SignatureKind
        publisher = [string]$Evidence.Publisher
        signer_subject = $signer.Certificate.Subject
        signature_sha256 = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        cms_signature_verified = $true
        timestamp_binding_verified = $true
        timestamp = $timestamp.ToString('O')
        timestamp_authority = $tsaCertificate.Subject
        signer_chain_valid = $true
        timestamp_chain_valid = $true
        certificate_expired_now = $VerificationTime -gt [datetimeoffset]$signer.Certificate.NotAfter
        evidence_source = 'supplied-evidence'
        trust_source = $(if ($TrustRoot.Count -gt 0) { 'explicit-test-roots' } else { 'system-trust' })
        revocation = 'not-checked-offline'
        verification_scope = 'identity-metadata-and-cms-timestamp;payload-digests-not-checked'
    }
}

Export-ModuleMember -Function Test-OfficialPackageSignatureEvidence
