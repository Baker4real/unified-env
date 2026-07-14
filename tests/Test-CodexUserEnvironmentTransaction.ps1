$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$productionHelperPath = Join-Path $projectRoot 'scripts\lib\CodexUserEnvironmentTransaction.cs'
Assert-True (Test-Path -LiteralPath $productionHelperPath -PathType Leaf) 'RED: production HKCU Environment TxR helper 尚不存在'
if (-not ('CodexHookGovernance.UserEnvironmentTransaction' -as [type])) {
    Add-Type -Path $productionHelperPath
}

if (-not ('CodexUserEnvironmentTxrProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

public static class CodexUserEnvironmentTxrProbe
{
    private static readonly UIntPtr HKEY_CURRENT_USER = new UIntPtr(0x80000001u);
    private const int KEY_QUERY_VALUE = 0x0001;
    private const int KEY_SET_VALUE = 0x0002;
    private const int REG_OPTION_NON_VOLATILE = 0;
    private const int ERROR_SUCCESS = 0;
    private const int REG_SZ = 1;

    [DllImport("ktmw32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateTransaction(
        IntPtr transactionAttributes, IntPtr uow, uint createOptions,
        uint isolationLevel, uint isolationFlags, uint timeout, string description);

    [DllImport("ktmw32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CommitTransaction(SafeFileHandle transactionHandle);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int RegOpenKeyTransactedW(
        UIntPtr hKey, string subKey, int options, int samDesired,
        out SafeRegistryHandle result, SafeFileHandle transaction, IntPtr extendedParameter);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int RegSetValueExW(
        SafeRegistryHandle hKey, string valueName, int reserved, int type,
        byte[] data, int dataSize);

    public static int SetStringThenCommit(string subKey, string valueName, string value)
    {
        using (SafeFileHandle transaction = CreateTransaction(
            IntPtr.Zero, IntPtr.Zero, 0, 0, 0, 0, "Codex User environment TxR fixture"))
        {
            if (transaction.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            SafeRegistryHandle key;
            int opened = RegOpenKeyTransactedW(
                HKEY_CURRENT_USER, subKey, REG_OPTION_NON_VOLATILE,
                KEY_QUERY_VALUE | KEY_SET_VALUE, out key, transaction, IntPtr.Zero);
            if (opened != ERROR_SUCCESS) throw new Win32Exception(opened);
            using (key)
            {
                byte[] data = System.Text.Encoding.Unicode.GetBytes(value + "\0");
                int written = RegSetValueExW(key, valueName, 0, REG_SZ, data, data.Length);
                if (written != ERROR_SUCCESS) throw new Win32Exception(written);
                if (CommitTransaction(transaction)) return ERROR_SUCCESS;
                return Marshal.GetLastWin32Error();
            }
        }
    }

    public static void WriteRawStringValue(string subKey, string valueName, int type, byte[] bytes)
    {
        using (RegistryKey key = Registry.CurrentUser.OpenSubKey(subKey, true))
        {
            if (key == null) throw new InvalidOperationException("fixture key missing");
            int written = RegSetValueExW(key.Handle, valueName, 0, type, bytes, bytes.Length);
            if (written != ERROR_SUCCESS) throw new Win32Exception(written);
        }
    }

    public static Task<int> BeginStringThenWaitAndCommit(
        string subKey, string valueName, string value,
        ManualResetEventSlim transactionReady, ManualResetEventSlim allowCommit)
    {
        return Task.Run(() =>
        {
            using (SafeFileHandle transaction = CreateTransaction(
                IntPtr.Zero, IntPtr.Zero, 0, 0, 0, 0, "Codex User environment TxR conflict fixture"))
            {
                if (transaction.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                SafeRegistryHandle key;
                int opened = RegOpenKeyTransactedW(
                    HKEY_CURRENT_USER, subKey, REG_OPTION_NON_VOLATILE,
                    KEY_QUERY_VALUE | KEY_SET_VALUE, out key, transaction, IntPtr.Zero);
                if (opened != ERROR_SUCCESS) throw new Win32Exception(opened);
                using (key)
                {
                    byte[] data = System.Text.Encoding.Unicode.GetBytes(value + "\0");
                    int written = RegSetValueExW(key, valueName, 0, REG_SZ, data, data.Length);
                    if (written != ERROR_SUCCESS) throw new Win32Exception(written);
                    transactionReady.Set();
                    if (!allowCommit.Wait(5000)) throw new TimeoutException("fixture did not release transaction");
                    if (CommitTransaction(transaction)) return ERROR_SUCCESS;
                    return Marshal.GetLastWin32Error();
                }
            }
        });
    }
}
'@
}

$relativeKey = 'Software\Codex\HookFixtures\' + [guid]::NewGuid().ToString('N')
$valueName = 'SERENA_HOME'
try {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($relativeKey, $true)
    try { $key.SetValue($valueName, 'before', [Microsoft.Win32.RegistryValueKind]::String) }
    finally { $key.Dispose() }

    [CodexHookGovernance.UserEnvironmentTransaction]::SetFixtureValue(
        $relativeKey, 'before', [CodexHookGovernance.UserEnvironmentValueKind]::String,
        'production-helper-value', [CodexHookGovernance.UserEnvironmentValueKind]::String)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relativeKey, $false)
    try {
        Assert-True (([string]$key.GetValue($valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) -ceq 'production-helper-value') 'production TxR helper 必须发布 REG_SZ'
        Assert-True ($key.GetValueKind($valueName) -eq [Microsoft.Win32.RegistryValueKind]::String) 'production TxR helper 必须保持 REG_SZ 类型'
    }
    finally { $key.Dispose() }

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relativeKey, $true)
    try { $key.SetValue($valueName, '%TEMP%\serena', [Microsoft.Win32.RegistryValueKind]::ExpandString) }
    finally { $key.Dispose() }
    [CodexHookGovernance.UserEnvironmentTransaction]::SetFixtureValue(
        $relativeKey, '%TEMP%\serena', [CodexHookGovernance.UserEnvironmentValueKind]::ExpandString,
        'normalized', [CodexHookGovernance.UserEnvironmentValueKind]::String)
    [CodexHookGovernance.UserEnvironmentTransaction]::SetFixtureValue(
        $relativeKey, 'normalized', [CodexHookGovernance.UserEnvironmentValueKind]::String,
        '%TEMP%\serena', [CodexHookGovernance.UserEnvironmentValueKind]::ExpandString)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relativeKey, $false)
    try {
        Assert-True ($key.GetValueKind($valueName) -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) 'restore 必须恢复 REG_EXPAND_SZ 类型'
        Assert-True (([string]$key.GetValue($valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) -ceq '%TEMP%\serena') 'restore 必须恢复 REG_EXPAND_SZ 原文'
    }
    finally { $key.Dispose() }

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relativeKey, $true)
    try { $key.DeleteValue($valueName, $false) }
    finally { $key.Dispose() }
    [CodexHookGovernance.UserEnvironmentTransaction]::SetFixtureValue(
        $relativeKey, [System.Management.Automation.Language.NullString]::Value, [CodexHookGovernance.UserEnvironmentValueKind]::Missing,
        'created', [CodexHookGovernance.UserEnvironmentValueKind]::String)
    [CodexHookGovernance.UserEnvironmentTransaction]::SetFixtureValue(
        $relativeKey, 'created', [CodexHookGovernance.UserEnvironmentValueKind]::String,
        [System.Management.Automation.Language.NullString]::Value, [CodexHookGovernance.UserEnvironmentValueKind]::Missing)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relativeKey, $false)
    try { Assert-True ($null -eq $key.GetValue($valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) 'restore 必须恢复 value 缺失状态' }
    finally { $key.Dispose() }

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relativeKey, $true)
    try { $key.SetValue($valueName, 7, [Microsoft.Win32.RegistryValueKind]::DWord) }
    finally { $key.Dispose() }
    $unsupportedThrew = $false
    try {
        [CodexHookGovernance.UserEnvironmentTransaction]::SetFixtureValue(
            $relativeKey, '7', [CodexHookGovernance.UserEnvironmentValueKind]::String,
            'must-not-write', [CodexHookGovernance.UserEnvironmentValueKind]::String)
    }
    catch { $unsupportedThrew = $_.Exception.Message -match 'unsupported' }
    Assert-True $unsupportedThrew 'production TxR helper 必须在写前拒绝非 REG_SZ/REG_EXPAND_SZ 类型'

    $decodeMethod = [CodexHookGovernance.UserEnvironmentTransaction].GetMethod(
        'DecodeRegistryString',
        [Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Static)
    Assert-True ($null -ne $decodeMethod) 'registry string decoder 必须存在'
    foreach ($malformed in @(
        @{ name = 'odd-byte-count'; bytes = [byte[]](0x41,0x00,0x42) },
        @{ name = 'missing-nul'; bytes = [byte[]](0x41,0x00) },
        @{ name = 'embedded-nul'; bytes = [byte[]](0x41,0x00,0x00,0x00,0x42,0x00,0x00,0x00) }
    )) {
        $malformedThrew = $false
        $malformedError = $null
        try {
            $null = $decodeMethod.Invoke($null, @($malformed.bytes, [int]$malformed.bytes.Length))
        }
        catch {
            $errorObject = $_.Exception
            while ($null -ne $errorObject.InnerException) { $errorObject = $errorObject.InnerException }
            $malformedError = $errorObject.Message
            $malformedThrew = $malformedError -match 'registry string encoding'
        }
        Assert-True $malformedThrew "production TxR helper 必须拒绝 malformed registry string：$($malformed.name)；actual=$malformedError"
    }

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relativeKey, $true)
    try { $key.SetValue($valueName, 'before-conflict', [Microsoft.Win32.RegistryValueKind]::String) }
    finally { $key.Dispose() }
    $productionReady = [Threading.ManualResetEventSlim]::new($false)
    $productionCommit = [Threading.ManualResetEventSlim]::new($false)
    try {
        $productionTask = [CodexHookGovernance.UserEnvironmentTransaction]::SetFixtureValueWithBarrier(
            $relativeKey, 'before-conflict', [CodexHookGovernance.UserEnvironmentValueKind]::String,
            'must-not-win', [CodexHookGovernance.UserEnvironmentValueKind]::String,
            $productionReady, $productionCommit)
        Assert-True ($productionReady.Wait(5000)) 'production TxR helper 未到达 commit 前 seam'
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relativeKey, $true)
        try { $key.SetValue($valueName, 'competing-production-value', [Microsoft.Win32.RegistryValueKind]::String) }
        finally { $key.Dispose() }
        $productionCommit.Set()
        $productionConflictThrew = $false
        try { $productionTask.GetAwaiter().GetResult() }
        catch { $productionConflictThrew = $true }
        Assert-True $productionConflictThrew 'production TxR helper 的 conflict commit 必须 fail-closed'
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relativeKey, $false)
        try { Assert-True (([string]$key.GetValue($valueName)) -ceq 'competing-production-value') 'production TxR conflict 必须保留竞争值' }
        finally { $key.Dispose() }
    }
    finally {
        $productionCommit.Set()
        $productionCommit.Dispose()
        $productionReady.Dispose()
    }

    $noConflict = [CodexUserEnvironmentTxrProbe]::SetStringThenCommit($relativeKey, $valueName, 'transaction-value')
    Assert-True ($noConflict -eq 0) "无竞争 TxR commit 必须成功：win32=$noConflict"
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relativeKey, $false)
    try { Assert-True (([string]$key.GetValue($valueName)) -ceq 'transaction-value') '无竞争 TxR 必须发布事务值' }
    finally { $key.Dispose() }

    $transactionReady = [Threading.ManualResetEventSlim]::new($false)
    $allowCommit = [Threading.ManualResetEventSlim]::new($false)
    try {
        $transactionTask = [CodexUserEnvironmentTxrProbe]::BeginStringThenWaitAndCommit(
            $relativeKey, $valueName, 'must-not-win', $transactionReady, $allowCommit)
        Assert-True ($transactionReady.Wait(5000)) 'TxR conflict fixture 未到达 commit 前 seam'
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relativeKey, $true)
        try { $key.SetValue($valueName, 'competing-value', [Microsoft.Win32.RegistryValueKind]::String) }
        finally { $key.Dispose() }
        $allowCommit.Set()
        $commitCode = $transactionTask.GetAwaiter().GetResult()
        Assert-True ($commitCode -ne 0) '竞争的非事务写入必须使 TxR commit 失败'
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relativeKey, $false)
        try { Assert-True (([string]$key.GetValue($valueName)) -ceq 'competing-value') 'TxR commit 失败后必须保留竞争值' }
        finally { $key.Dispose() }
    }
    finally {
        if ($null -ne $allowCommit) { $allowCommit.Set(); $allowCommit.Dispose() }
        if ($null -ne $transactionReady) { $transactionReady.Dispose() }
    }
}
finally {
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($relativeKey, $false)
}

$reconcilerPath = Join-Path $projectRoot 'scripts\Invoke-CodexHostHookReconciliation.ps1'
$reconcilerText = Get-Content -LiteralPath $reconcilerPath -Raw
Assert-True (-not $reconcilerText.Contains('SetFixtureValue', [StringComparison]::Ordinal)) 'production reconciler 不得调用 fixture TxR API'
Assert-True (-not $reconcilerText.Contains('Software\Codex\HookFixtures', [StringComparison]::OrdinalIgnoreCase)) 'production reconciler 不得接受 fixture registry subkey'
Assert-True (-not $reconcilerText.Contains('SetEnvironmentVariable(', [StringComparison]::Ordinal)) 'production reconciler 不得回退普通 User environment Set'
Assert-True ($reconcilerText.Contains('SetUserSerenaHome', [StringComparison]::Ordinal)) 'production reconciler live env 分支必须调用固定 TxR helper'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($reconcilerPath, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'production reconciler AST 必须合法'
$parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
Assert-True (($parameterNames -join ',') -ceq 'Mode,CodexHome,EvidencePath,Json') 'production CLI 只允许固定 Restore evidence 参数，不得暴露 registry subkey/test capability 参数'
