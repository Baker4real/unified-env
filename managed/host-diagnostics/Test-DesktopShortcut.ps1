#Requires -Version 7.5
[CmdletBinding()]
param([string]$EvidenceRoot = 'D:/agents/run-evidence/desktop-shortcut-tests')

$ErrorActionPreference = 'Stop'
$runRoot = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ([guid]::NewGuid().ToString('N'))
if ([IO.Path]::GetPathRoot($runRoot) -ine 'D:\') { throw 'Fixture output requires D:.' }
[void][IO.Directory]::CreateDirectory($runRoot)
$entry = Join-Path $PSScriptRoot 'Open-DesktopShortcut.ps1'
$link = Join-Path $runRoot 'shortcut with spaces.lnk'
$target = Join-Path $env:SystemRoot 'explorer.exe'
$other = Join-Path $env:SystemRoot 'System32/cmd.exe'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($link)
$shortcut.TargetPath = $target
$shortcut.Arguments = '/n'
$shortcut.Save()

$plan = & $entry -Mode Plan -ShortcutPath $link -ExpectedTarget $target -ExecutablePath $other -ExpectedArguments '/n'
if ($plan.status -ne 'planned' -or $plan.target -ne $target -or $plan.executable -ne [IO.Path]::GetFullPath($other)) {
    throw 'The desktop plan did not bind the observed link and expected window executable.'
}
foreach ($case in @(@{target=$other; arguments='/n'}, @{target=$target; arguments=''})) {
    $refused = $false
    try { $null = & $entry -Mode Plan -ShortcutPath $link -ExpectedTarget $case.target -ExecutablePath $other -ExpectedArguments $case.arguments }
    catch { $refused = $_.Exception.Message -eq 'shortcut-target-or-arguments-changed' }
    if (-not $refused) { throw 'The desktop plan accepted shortcut drift.' }
}
'Explorer shortcut plan verified target binding, arguments and drift refusal.'

# Use the real shortcut entry and replace only the Windows process boundaries.
$app = Join-Path $runRoot 'Antigravity.exe'
[IO.File]::WriteAllText($app, 'Identity fixture. Never execute this file.')
$created = [datetime]::new(2026, 1, 1, 0, 0, 1, [DateTimeKind]::Utc)
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class DesktopShortcutWindowFixture {
    private const string ClassName = "Chrome_WidgetWin_1";
    private delegate IntPtr WndProc(IntPtr hwnd, uint message, UIntPtr wp, IntPtr lp);
    private static readonly WndProc handler = DefWindowProcW;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WindowClass {
        public uint style;
        public WndProc proc;
        public int clsExtra, winExtra;
        public IntPtr instance, icon, cursor, background;
        public string menu, name;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Message {
        public IntPtr hwnd;
        public uint id;
        public UIntPtr wp;
        public IntPtr lp;
        public uint time;
        public int x, y;
        public uint reserved;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern IntPtr GetModuleHandleW(string name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern ushort RegisterClassW(ref WindowClass wc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern IntPtr CreateWindowExW(uint ex, string cls, string title, uint style, int x, int y,
        int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern IntPtr DefWindowProcW(IntPtr hwnd, uint message, UIntPtr wp, IntPtr lp);
    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll", ExactSpelling = true)]
    public static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern bool PeekMessageW(out Message message, IntPtr hwnd, uint min, uint max, uint flags);

    private static readonly IntPtr instance = GetModuleHandleW(null);
    static DesktopShortcutWindowFixture() {
        var windowClass = new WindowClass { proc = handler, instance = instance, name = ClassName };
        if (RegisterClassW(ref windowClass) == 0) throw new Win32Exception();
    }
    public static IntPtr Open(bool applicationFrame) {
        // Antigravity 2.34 uses a resizable captioned frame without WS_SYSMENU.
        uint style = applicationFrame ? 0x04c70000u : 0x80000000u;
        IntPtr hwnd = CreateWindowExW(0x08000000, ClassName, "Desktop shortcut fixture", style,
            -30000, -30000, 640, applicationFrame ? 480 : 86, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
        if (hwnd == IntPtr.Zero) throw new Win32Exception();
        ShowWindow(hwnd, 8); // SW_SHOWNA, without activating the fixture
        return hwnd;
    }
    public static bool ReadClose(IntPtr hwnd) {
        return PeekMessageW(out _, hwnd, 0x0010, 0x0010, 1);
    }
}
'@
$desktopProcessId = $PID
$fixtureCases = @(
    @{name='valid-main'; expected='explorer-launch-refused-9'; ids=@(8102,8103,8101)},
    @{name='wait-timeout'; expected='app-did-not-close-normally'; ids=@(8101)},
    @{name='renderer'; expected='antigravity-desktop-main-identity-unverified'; ids=@(8102)},
    @{name='node-wrapper'; expected='antigravity-desktop-main-identity-unverified'; ids=@(8103)},
    @{name='missing-command-line'; expected='antigravity-desktop-main-identity-unverified'; ids=@(8101)},
    @{name='missing-cim-row'; expected='antigravity-desktop-main-identity-unverified'; ids=@(8101)},
    @{name='pid-reused'; expected='antigravity-desktop-main-identity-changed'; ids=@(8101)},
    @{name='window-changed'; expected='antigravity-desktop-main-identity-changed'; ids=@(8101)},
    @{name='role-changed'; expected='antigravity-desktop-main-identity-changed'; ids=@(8101)},
    @{name='headless-main'; expected='antigravity-desktop-main-identity-unverified'; ids=@(8101); headless=$true},
    @{name='headless-helpers'; expected='explorer-launch-refused-9'; ids=@(8102,8103); headless=$true},
    @{name='no-existing-process'; expected='explorer-launch-refused-9'; ids=@()},
    @{name='ambiguous-frames'; expected='more-than-one-matching-app-window'; ids=@(8101)}
)

function Get-Process($Id, $Name) {
    if ($Name -eq 'explorer') { return [pscustomobject]@{SessionId=7; Path=$target} }
    $processIds = if ($Id -eq $desktopProcessId) { @(8101) } elseif ($Id) { @($Id) } else { $fixtureCase.ids }
    foreach ($processId in $processIds) {
        $process = [pscustomobject]@{
            Id=$(if ($processId -eq 8101) { $desktopProcessId } else { $processId }); SessionId=7; Path=$app
            MainWindowHandle=$(if ($processId -eq 8101) { $osState.tooltip } else { [IntPtr]($processId + 100) })
            StartTime=$created
            HasExited=$false; SafeHandle=[pscustomobject]@{IsInvalid=$false; IsClosed=$false}
            Closed=$osState.closed; Waited=$osState.waited; ExitsOnClose=($fixtureCase.name -ne 'wait-timeout')
        }
        if ($fixtureCase.headless) { $process.MainWindowHandle = [IntPtr]::Zero }
        $process | Add-Member ScriptMethod CloseMainWindow { $this.Closed.Add($this.Id); $true }
        $process | Add-Member ScriptMethod WaitForExit { $this.Waited.Add($this.Id); $this.ExitsOnClose }
        $process | Add-Member ScriptMethod Refresh {}
        $process | Add-Member ScriptMethod Dispose {}
        $process
    }
}
function Get-CimInstance($ClassName, $Filter, $Property) {
    if ($Filter -like "*Name = 'cmd.exe'") {
        $cmd = Join-Path $env:SystemRoot 'System32/cmd.exe'
        return [pscustomobject]@{
            ProcessId=8002; SessionId=7; ExecutablePath=$cmd; CreationDate=$created.AddSeconds(-1)
            CommandLine=('"{0}" /d /s /c ""D:\Fixture with spaces\node.cmd" preload.mjs"' -f $cmd)
        }
    }
    if ($fixtureCase.name -eq 'missing-cim-row') { return }
    $isReadBack = $Filter.EndsWith("ProcessId = $desktopProcessId")
    if ($isReadBack -and $fixtureCase.name -eq 'window-changed') {
        if (-not [DesktopShortcutWindowFixture]::DestroyWindow($osState.main)) { throw 'Fixture could not retire the first window.' }
        $osState.main = [DesktopShortcutWindowFixture]::Open($true)
    }
    $rows = if ($isReadBack) { @(8101) } else { $fixtureCase.ids }
    foreach ($processId in $rows) {
        $arguments = switch ($processId) {
            8102 { ' --type=renderer' }
            8103 { ' --import preload.mjs' }
            default { if ($isReadBack -and $fixtureCase.name -eq 'role-changed') { ' --type=utility' } else { '' } }
        }
        [pscustomobject]@{
            ProcessId=$(if ($processId -eq 8101) { $desktopProcessId } else { $processId }); ParentProcessId=$(if ($processId -eq 8103) { 8002 } else { 8001 })
            SessionId=7; ExecutablePath=$app
            CreationDate=$(if ($isReadBack -and $fixtureCase.name -eq 'pid-reused') { $created.AddSeconds(1) } else { $created })
            CommandLine=$(if ($fixtureCase.name -ne 'missing-command-line') { '"{0}"{1}' -f $app, $arguments })
        }
    }
}
function Invoke-CimMethod($ClassName, $MethodName, $Arguments) {
    $osState.launchCalls++
    [pscustomobject]@{ReturnValue=9}
}

foreach ($fixtureCase in $fixtureCases) {
    $osState = @{
        closed=[Collections.Generic.List[int]]::new(); waited=[Collections.Generic.List[int]]::new(); launchCalls=0; idReads=0
        main=[IntPtr]::Zero; tooltip=[IntPtr]::Zero; second=[IntPtr]::Zero
    }
    try {
        if (8101 -in $fixtureCase.ids -and -not $fixtureCase.headless) {
            $osState.main = [DesktopShortcutWindowFixture]::Open($true)
            $osState.tooltip = [DesktopShortcutWindowFixture]::Open($false)
        }
        if ($fixtureCase.name -eq 'ambiguous-frames') { $osState.second = [DesktopShortcutWindowFixture]::Open($true) }
        $reason = $null
        try { $null = & $entry -Mode Restart -ShortcutPath $link -ExpectedTarget $target -ExecutablePath $app -ExpectedArguments '/n' }
        catch { $reason = $_.Exception.Message }
        $closeMain = $osState.main -ne 0 -and [DesktopShortcutWindowFixture]::ReadClose($osState.main)
        $closeTooltip = $osState.tooltip -ne 0 -and [DesktopShortcutWindowFixture]::ReadClose($osState.tooltip)
        if ($reason -cne $fixtureCase.expected) { throw "Unexpected restart result for $($fixtureCase.name): $reason" }
        if ($fixtureCase.name -in 'valid-main', 'wait-timeout') {
            $expectedLaunches = [int]($fixtureCase.name -eq 'valid-main')
            if (-not $closeMain -or $closeTooltip -or $osState.closed.Count -or
                ($osState.waited -join ',') -ne "$desktopProcessId" -or $osState.launchCalls -ne $expectedLaunches) {
                throw 'Restart must send WM_CLOSE to the exact application frame, even when the OS reports the tooltip.'
            }
        } else {
            $expectedLaunches = [int]($fixtureCase.expected -eq 'explorer-launch-refused-9')
            $closeSecond = $osState.second -ne 0 -and [DesktopShortcutWindowFixture]::ReadClose($osState.second)
            if ($closeMain -or $closeTooltip -or $closeSecond -or $osState.closed.Count -or $osState.waited.Count -or $osState.launchCalls -ne $expectedLaunches) {
                throw 'Restart did not isolate unproven identities from close and launch actions.'
            }
        }
    } finally {
        foreach ($hwnd in @($osState.main, $osState.tooltip, $osState.second)) {
            if ($hwnd -ne 0) { [void][DesktopShortcutWindowFixture]::DestroyWindow($hwnd) }
        }
    }
}
'Antigravity Desktop restart sent close only to the application frame and refused ambiguous, missing or changed identity.'
