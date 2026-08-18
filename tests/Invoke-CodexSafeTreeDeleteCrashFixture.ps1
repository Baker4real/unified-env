[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TransactionPath,
    [Parameter(Mandatory)][string]$ApprovedTransactionSha256,
    [Parameter(Mandatory)][string]$FixturePolicyPath,
    [Parameter(Mandatory)][string]$FixtureEvidenceRoot,
    [Parameter(Mandatory)][string]$MarkerRoot,
    [Parameter(Mandatory)]
    [ValidateSet(
        'ConcurrentAds',
        'PreopenedAds',
        'AclDriftAfterFreeze',
        'FailFastAfterFreeze',
        'CommitPublishReturnFailure',
        'FailFastAfterCommit',
        'FailFastAfterPending',
        'FailFastAfterLeafDelete',
        'FailFastAfterLeafDispositionsPublish')]
    [string]$Scenario
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class CodexSafeDeleteCrashStreamFixture
{
    private const uint GenericWrite = 0x40000000;
    private const uint OpenAlways = 4;
    private const uint FileAttributeNormal = 0x80;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private static FileStream heldStream;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string name,
        uint access,
        FileShare share,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    public static void WriteNamedStream(string directoryPath, string streamName, string value)
    {
        SafeFileHandle handle = CreateFileW(
            directoryPath + ":" + streamName,
            GenericWrite,
            FileShare.Read | FileShare.Write | FileShare.Delete,
            IntPtr.Zero,
            OpenAlways,
            FileAttributeNormal | FileFlagOpenReparsePoint,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, "Native crash fixture stream open failed.");
        }
        using (FileStream stream = new FileStream(handle, FileAccess.Write))
        {
            byte[] bytes = new UTF8Encoding(false).GetBytes(value);
            stream.SetLength(0);
            stream.Write(bytes, 0, bytes.Length);
            stream.Flush(true);
        }
    }

    public static void OpenHeldNamedStream(string directoryPath, string streamName, string value)
    {
        if (heldStream != null)
        {
            throw new InvalidOperationException("The crash fixture already holds a named stream.");
        }
        SafeFileHandle handle = CreateFileW(
            directoryPath + ":" + streamName,
            GenericWrite,
            FileShare.Read | FileShare.Write | FileShare.Delete,
            IntPtr.Zero,
            OpenAlways,
            FileAttributeNormal | FileFlagOpenReparsePoint,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, "Native held-stream fixture open failed.");
        }
        heldStream = new FileStream(handle, FileAccess.Write);
        byte[] bytes = new UTF8Encoding(false).GetBytes(value);
        heldStream.SetLength(0);
        heldStream.Write(bytes, 0, bytes.Length);
        heldStream.Flush(true);
    }
}
'@ -ErrorAction Stop

function Write-DurableMarker {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Value
    )

    [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
    $stream = [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::Read,
        4096,
        [IO.FileOptions]::WriteThrough)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

$checkpoint = {
    param(
        [string]$DirectoryPath,
        [string]$RelativePath,
        [string]$Phase,
        [string]$FreezeIntentPath,
        [string]$CommitIntentPath,
        [string]$AbortIntentPath
    )

    $markerValue = [pscustomobject][ordered]@{
        phase = $Phase
        directoryPath = $DirectoryPath
        relativePath = $RelativePath
        freezeIntentPath = $FreezeIntentPath
        commitIntentPath = $CommitIntentPath
        abortIntentPath = $AbortIntentPath
    } | ConvertTo-Json -Compress
    switch ($Scenario) {
        'ConcurrentAds' {
            if ($Phase -ceq 'before-stream-freeze') {
                Write-DurableMarker `
                    -Path (Join-Path $MarkerRoot 'before-stream-freeze.marker') `
                    -Value $markerValue
                [CodexSafeDeleteCrashStreamFixture]::WriteNamedStream(
                    $DirectoryPath,
                    'crash-window',
                    'must-survive')
            }
        }
        'PreopenedAds' {
            if ($Phase -ceq 'before-stream-freeze') {
                Write-DurableMarker `
                    -Path (Join-Path $MarkerRoot 'preopened-ads.marker') `
                    -Value $markerValue
                [CodexSafeDeleteCrashStreamFixture]::OpenHeldNamedStream(
                    $DirectoryPath,
                    'held-crash-window',
                    'held-must-survive')
            }
        }
        'AclDriftAfterFreeze' {
            if ($Phase -ceq 'after-stream-freeze') {
                $freezeIntent = Get-Content -Raw -LiteralPath $FreezeIntentPath |
                    ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
                $acl = Get-Acl -LiteralPath $DirectoryPath -ErrorAction Stop
                $acl.SetSecurityDescriptorSddlForm(
                    [string]$freezeIntent.originalSecurityDescriptorSddl)
                Set-Acl -LiteralPath $DirectoryPath -AclObject $acl -ErrorAction Stop
                Write-DurableMarker `
                    -Path (Join-Path $MarkerRoot 'acl-drift-after-freeze.marker') `
                    -Value $markerValue
            }
        }
        'FailFastAfterFreeze' {
            if ($Phase -ceq 'after-stream-freeze') {
                Write-DurableMarker `
                    -Path (Join-Path $MarkerRoot 'after-stream-freeze.marker') `
                    -Value $markerValue
                [Environment]::FailFast('safe-delete crash fixture after stream freeze')
            }
        }
        'CommitPublishReturnFailure' {
            if ($Phase -ceq 'after-commit-publish-before-return') {
                Write-DurableMarker `
                    -Path (Join-Path $MarkerRoot 'commit-publish-return-failure.marker') `
                    -Value $markerValue
                throw 'safe-delete fixture failure after commit publish before callback return'
            }
        }
        'FailFastAfterCommit' {
            if ($Phase -ceq 'after-commit-intent') {
                Write-DurableMarker `
                    -Path (Join-Path $MarkerRoot 'after-commit-intent.marker') `
                    -Value $markerValue
                [Environment]::FailFast('safe-delete crash fixture after commit intent')
            }
        }
        'FailFastAfterPending' {
            if ($Phase -ceq 'after-delete-pending' -and $RelativePath -ceq '.') {
                Write-DurableMarker `
                    -Path (Join-Path $MarkerRoot 'after-delete-pending.marker') `
                    -Value $markerValue
                [Environment]::FailFast('safe-delete crash fixture after delete-pending')
            }
        }
    }
}

$leafCheckpoint = {
    param([string]$Path, [string]$Kind)

    if ($Scenario -cne 'FailFastAfterLeafDelete') { return }
    $markerValue = [pscustomobject][ordered]@{
        path = $Path
        kind = $Kind
    } | ConvertTo-Json -Compress
    Write-DurableMarker `
        -Path (Join-Path $MarkerRoot 'after-leaf-delete.marker') `
        -Value $markerValue
    [Environment]::FailFast('safe-delete crash fixture after leaf delete')
}

$publishCheckpoint = {
    param([string]$Path, [string]$Sha256)

    if ($Scenario -cne 'FailFastAfterLeafDispositionsPublish') { return }
    $markerValue = [pscustomobject][ordered]@{
        path = $Path
        sha256 = $Sha256
    } | ConvertTo-Json -Compress
    Write-DurableMarker `
        -Path (Join-Path $MarkerRoot 'after-leaf-dispositions-publish.marker') `
        -Value $markerValue
    [Environment]::FailFast('safe-delete crash fixture after leaf dispositions publish')
}

Invoke-CodexSafeTreeDeletePurge `
    -TransactionPath $TransactionPath `
    -ApprovedTransactionSha256 $ApprovedTransactionSha256 `
    -PolicyPath $FixturePolicyPath `
    -EvidenceRoot $FixtureEvidenceRoot `
    -DirectoryDeleteCheckpointForTest $checkpoint `
    -LeafDeleteCheckpointForTest $leafCheckpoint `
    -AfterLeafDispositionsPublishForTest $publishCheckpoint
