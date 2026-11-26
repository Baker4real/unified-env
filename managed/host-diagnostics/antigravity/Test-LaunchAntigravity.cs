using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

internal static class TestLauncher
{
    [STAThread]
    private static void Main(string[] args)
    {
        if (args.Length > 0)
        {
            if (args.Length != 1)
                throw new ArgumentException("Expected a single launcher fixture action.");
            var assemblyDirectory = Path.GetDirectoryName(typeof(TestLauncher).Assembly.Location);
            if (args[0] == "--fixture-desktop")
            {
                ValidateUpgradeRoot(Path.GetDirectoryName(assemblyDirectory));
                using (var window = new Form { Text = "Antigravity launcher fixture", WindowState = FormWindowState.Minimized })
                using (var lifetime = new System.Windows.Forms.Timer { Interval = 20000 })
                {
                    lifetime.Tick += (sender, e) => window.Close();
                    lifetime.Start();
                    Application.Run(window);
                }
                return;
            }
            if (args[0] != "--reconcile-fixture" && args[0] != "--reconcile-reopened-fixture")
                throw new ArgumentException("Unknown launcher fixture action.");
            try { ValidateUpgradeRoot(assemblyDirectory); }
            catch (InvalidOperationException error)
            {
                Console.Error.WriteLine(error.Message);
                Environment.ExitCode = 1;
                return;
            }
            var appPath = Path.Combine(assemblyDirectory, "app", "Antigravity.exe");
            var stateDir = Path.Combine(assemblyDirectory, "state");
            Func<LaunchAntigravity.ReconcileOutcome> prepare = () => LaunchAntigravity.PrepareAddonsForLaunch(
                appPath, stateDir, null, null);
            var outcome = args[0] == "--reconcile-reopened-fixture" ? WithDesktopFixture(appPath, prepare) : prepare();
            Console.WriteLine(outcome);
            return;
        }

        var environment = new StringDictionary();
        environment["HTTPS_PROXY"] = "http://127.0.0.1:17897";
        environment["NO_PROXY"] = "localhost";

        LaunchAntigravity.ApplyProxy(environment, "127.0.0.1:7688");
        Expect(environment["HTTPS_PROXY"], "http://127.0.0.1:7688", "MESL replaces inherited Clash");
        Expect(environment["HTTP_PROXY"], "http://127.0.0.1:7688", "shared HTTP proxy");
        Expect(environment["ALL_PROXY"], "http://127.0.0.1:7688", "shared fallback proxy");

        LaunchAntigravity.ApplyProxy(environment, "127.0.0.1:17897;");
        Expect(environment["HTTPS_PROXY"], "http://127.0.0.1:17897", "switch back to Clash");
        LaunchAntigravity.ApplyProxy(environment, "http=127.0.0.1:7688;https=127.0.0.1:17897");
        Expect(environment["HTTP_PROXY"], "http://127.0.0.1:7688", "HTTP-specific proxy");
        Expect(environment["HTTPS_PROXY"], "http://127.0.0.1:17897", "HTTPS-specific proxy");
        Expect(environment["ALL_PROXY"], null, "separate routes clear the fallback");

        LaunchAntigravity.ApplyProxy(environment, null);
        Expect(environment["HTTPS_PROXY"], null, "system proxy off clears inherited HTTPS proxy");
        Expect(environment["HTTP_PROXY"], null, "system proxy off clears inherited HTTP proxy");
        Expect(environment["ALL_PROXY"], null, "system proxy off clears inherited fallback proxy");
        Expect(environment["NO_PROXY"], "localhost", "loopback bypass survives all switches");

        TestPreLaunchReconcile();
        Console.WriteLine("Antigravity launcher fixture passed.");
    }

    private static void ValidateUpgradeRoot(string directory)
    {
        if (!Regex.IsMatch(directory, @"\AD:\\(?:agents\\tmp|Codex\\temp)\\antigravity-addons-(?:unit|e2e)-[a-z0-9]{6}\\[a-z0-9-]+\z",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            throw new InvalidOperationException("Launcher upgrade requires a generated Antigravity fixture root.");
        AssertOrdinaryAncestry(directory);
        var pending = new Stack<string>();
        pending.Push(directory);
        while (pending.Count > 0)
        {
            foreach (var entry in Directory.EnumerateFileSystemEntries(pending.Pop()))
            {
                var attrs = File.GetAttributes(entry);
                if ((attrs & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidOperationException("Launcher fixture contains a reparse point: " + entry);
                if ((attrs & FileAttributes.Directory) != 0)
                    pending.Push(entry);
            }
        }
    }

    private static void AssertOrdinaryAncestry(string directory)
    {
        var parents = new Stack<string>();
        for (var dir = directory; dir != null; dir = Path.GetDirectoryName(dir))
            parents.Push(dir);
        foreach (var dir in parents)
        {
            var attrs = File.GetAttributes(dir);
            if ((attrs & FileAttributes.Directory) == 0 || (attrs & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("Launcher fixture requires ordinary directories: " + dir);
        }
    }

    private static LaunchAntigravity.ReconcileOutcome WithDesktopFixture(string appPath, Func<LaunchAntigravity.ReconcileOutcome> prepare)
    {
        File.Copy(typeof(TestLauncher).Assembly.Location, appPath);
        var start = new ProcessStartInfo(appPath, "--fixture-desktop")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = Path.GetDirectoryName(appPath),
        };
        using (var fixture = Process.Start(start))
        {
            if (fixture == null)
                throw new InvalidOperationException("The fixture desktop did not start.");
            try
            {
                var timer = Stopwatch.StartNew();
                while (!fixture.HasExited && timer.ElapsedMilliseconds < 8000)
                {
                    fixture.Refresh();
                    if (fixture.MainWindowHandle != IntPtr.Zero)
                        return prepare();
                    Thread.Sleep(25);
                }
                throw new InvalidOperationException("The fixture desktop did not become visible.");
            }
            finally
            {
                if (!fixture.HasExited && (!fixture.CloseMainWindow() || !fixture.WaitForExit(3000)))
                {
                    fixture.Kill();
                    fixture.WaitForExit(3000);
                }
            }
        }
    }

    private static void TestPreLaunchReconcile()
    {
        var evidence = Path.GetDirectoryName(typeof(TestLauncher).Assembly.Location);
        if (!Regex.IsMatch(evidence, @"\AD:\\agents\\run-evidence\\antigravity-launcher-tests\\[a-f0-9]{32}\z",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            throw new InvalidOperationException("Launcher fixture requires a generated evidence directory.");
        AssertOrdinaryAncestry(evidence);
        var tmpRoot = Path.Combine(evidence, "launcher-reconcile-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tmpRoot);
        try
        {
            var resDir = Path.Combine(tmpRoot, "resources");
            var binDir = Path.Combine(resDir, "bin");
            var stateDir = Path.Combine(tmpRoot, "state");
            Directory.CreateDirectory(binDir);
            Directory.CreateDirectory(stateDir);

            var asarPath = Path.Combine(resDir, "app.asar");
            var lsPath = Path.Combine(binDir, "language_server.exe");
            var fakeSync = Path.Combine(tmpRoot, "Sync.ps1");
            var fakePwsh = Path.Combine(tmpRoot, "pwsh.exe");
            File.WriteAllText(asarPath, "official-asar-v1", Encoding.UTF8);
            File.WriteAllText(lsPath, "official-ls-v1", Encoding.UTF8);
            File.WriteAllText(fakeSync, "# stub", Encoding.UTF8);
            File.WriteAllText(fakePwsh, "stub", Encoding.UTF8);

            var officialSha = LaunchAntigravity.ComputeSha256Hex(asarPath);
            var lsSha = LaunchAntigravity.ComputeSha256Hex(lsPath);

            // 1. Fast-path skip when active-build.json matches current app.asar + language_server.exe
            var activeJson = "{\"combinedSha256\":\"" + officialSha + "\",\"languageServerSha256\":\"" + lsSha + "\"}";
            File.WriteAllText(Path.Combine(stateDir, "active-build.json"), activeJson, Encoding.UTF8);
            int coldCalls = 0;
            var r1 = LaunchAntigravity.ReconcileAddonsBeforeLaunch(
                asarPath, stateDir, fakeSync, fakePwsh, () => false, (p, s) => { coldCalls++; return 0; });
            Expect(r1.ToString(), LaunchAntigravity.ReconcileOutcome.FastPathUpToDate.ToString(), "fast-path matches active-build.json");
            Expect(coldCalls.ToString(), "0", "fast-path must not invoke cold reconciler");

            // 2. Cold reconciler invoked when app.asar changes (official update) and desktop is not running
            File.WriteAllText(asarPath, "official-asar-v2", Encoding.UTF8);
            var officialV2Sha = LaunchAntigravity.ComputeSha256Hex(asarPath);
            var r2 = LaunchAntigravity.ReconcileAddonsBeforeLaunch(
                asarPath, stateDir, fakeSync, fakePwsh, () => false, (p, s) => { coldCalls++; return 0; });
            Expect(r2.ToString(), LaunchAntigravity.ReconcileOutcome.InvokedColdReconciler.ToString(), "cold reconciler runs on official update");
            Expect(coldCalls.ToString(), "1", "cold reconciler called once");

            // 3. Skipped when desktop is already running
            var r3 = LaunchAntigravity.ReconcileAddonsBeforeLaunch(
                asarPath, stateDir, fakeSync, fakePwsh, () => true, (p, s) => { coldCalls++; return 0; });
            Expect(r3.ToString(), LaunchAntigravity.ReconcileOutcome.SkippedDesktopRunning.ToString(), "skip mutation when desktop running");
            Expect(coldCalls.ToString(), "1", "cold reconciler not called while running");

            // 4. Corrupt/mismatched pending-app.asar is refused (falls back to cold reconciler, does not swap corrupt bytes)
            var pendingAsarPath = Path.Combine(stateDir, "pending-app.asar");
            var pendingMetaPath = Path.Combine(stateDir, "pending-apply.json");
            File.WriteAllText(pendingAsarPath, "corrupt-bytes", Encoding.UTF8);
            var fakeGoodSha = new string('a', 64);
            var badPendingJson = "{\"officialSha256\":\"" + officialV2Sha + "\",\"combinedSha256\":\"" + fakeGoodSha + "\",\"languageServerSha256\":\"" + lsSha + "\"}";
            File.WriteAllText(pendingMetaPath, badPendingJson, Encoding.UTF8);
            var r4 = LaunchAntigravity.ReconcileAddonsBeforeLaunch(
                asarPath, stateDir, fakeSync, fakePwsh, () => false, (p, s) => { coldCalls++; return 0; });
            Expect(r4.ToString(), LaunchAntigravity.ReconcileOutcome.InvokedColdReconciler.ToString(), "corrupt pending falls back safely");
            Expect(LaunchAntigravity.ComputeSha256Hex(asarPath), officialV2Sha, "corrupt pending must never overwrite app.asar");

            // 5. Valid pre-staged pending-app.asar swaps atomically without invoking cold reconciler
            File.WriteAllText(pendingAsarPath, "combined-asar-v2-verified", Encoding.UTF8);
            var combinedV2Sha = LaunchAntigravity.ComputeSha256Hex(pendingAsarPath);
            var goodPendingJson = "{\"officialSha256\":\"" + officialV2Sha + "\",\"replaceTargetSha256\":\"" + officialV2Sha + "\",\"combinedSha256\":\"" + combinedV2Sha + "\",\"languageServerSha256\":\"" + lsSha + "\"}";
            File.WriteAllText(pendingMetaPath, goodPendingJson, Encoding.UTF8);
            var r5 = LaunchAntigravity.ReconcileAddonsBeforeLaunch(
                asarPath, stateDir, fakeSync, fakePwsh, () => false, (p, s) => { coldCalls++; return 0; });
            Expect(r5.ToString(), LaunchAntigravity.ReconcileOutcome.AppliedPending.ToString(), "valid pending swaps immediately");
            Expect(LaunchAntigravity.ComputeSha256Hex(asarPath), combinedV2Sha, "app.asar matches promoted pending SHA");
            Expect(File.Exists(pendingAsarPath).ToString(), "False", "pending-app.asar cleaned up after promotion");
            Expect(File.Exists(pendingMetaPath).ToString(), "False", "pending-apply.json cleaned up after promotion");

            // 6. Immediate follow-up launch hits FastPathUpToDate against promoted active-build.json
            var r6 = LaunchAntigravity.ReconcileAddonsBeforeLaunch(
                asarPath, stateDir, fakeSync, fakePwsh, () => false, (p, s) => { coldCalls++; return 0; });
            Expect(r6.ToString(), LaunchAntigravity.ReconcileOutcome.FastPathUpToDate.ToString(), "promoted active-build enables fast-path");

            // 7. Production RunHiddenReconciler path (no delegate stand-in; exercises real pwsh.exe + ProcessStartInfo args)
            var realPwsh = ResolveRealPwsh();
            if (realPwsh == null)
                throw new InvalidOperationException("Unable to locate pwsh.exe for production RunHiddenReconciler verification.");
            var receiptPath = Path.Combine(tmpRoot, "real-reconciler-receipt.txt");
            var realStubScript = Path.Combine(tmpRoot, "Stub-Sync.ps1");
            File.WriteAllText(
                realStubScript,
                "param([string]$Mode, [switch]$Quiet)\n[IO.File]::WriteAllText('" + receiptPath.Replace("'", "''") + "', \"$Mode|$($Quiet.IsPresent)\")\n",
                Encoding.UTF8);
            File.WriteAllText(asarPath, "official-asar-v3-prod-path", Encoding.UTF8);
            var r7 = LaunchAntigravity.ReconcileAddonsBeforeLaunch(
                asarPath, stateDir, realStubScript, realPwsh, () => false, LaunchAntigravity.RunHiddenReconciler);
            Expect(r7.ToString(), LaunchAntigravity.ReconcileOutcome.InvokedColdReconciler.ToString(), "production RunHiddenReconciler invoked on official v3");
            if (!File.Exists(receiptPath))
                throw new InvalidOperationException("production RunHiddenReconciler did not execute the target script.");
            Expect(File.ReadAllText(receiptPath, Encoding.UTF8).Trim(), "Apply|True", "production RunHiddenReconciler passes -Mode Apply -Quiet");

            // 8. ResolvePwshPath picks highest versioned PowerShell directory when preferred version is retired
            var pwshTree = Path.Combine(tmpRoot, "pwsh-versions");
            var v769 = Path.Combine(pwshTree, "7.6.9");
            var v770 = Path.Combine(pwshTree, "7.7.0");
            var v782 = Path.Combine(pwshTree, "7.8.2");
            Directory.CreateDirectory(v769);
            Directory.CreateDirectory(v770);
            Directory.CreateDirectory(v782);
            File.WriteAllText(Path.Combine(v769, "pwsh.exe"), "stub", Encoding.UTF8);
            File.WriteAllText(Path.Combine(v770, "pwsh.exe"), "stub", Encoding.UTF8);
            var expectedNewest = Path.Combine(v782, "pwsh.exe");
            File.WriteAllText(expectedNewest, "stub", Encoding.UTF8);
            var missingPreferred = Path.Combine(pwshTree, "7.5.0", "pwsh.exe");
            Expect(
                LaunchAntigravity.ResolvePwshPath(missingPreferred, pwshTree, null),
                expectedNewest,
                "ResolvePwshPath selects highest versioned pwsh.exe");
            Expect(
                LaunchAntigravity.ResolvePwshPath(null, pwshTree, expectedNewest),
                null,
                "ResolvePwshPath preserves null pwshPath");

            // 9. Explicit process AppUserModelID aligns with upstream NSIS shortcut AUMID
            Expect(
                LaunchAntigravity.TryApplyProcessAppUserModelId(LaunchAntigravity.CanonicalAppUserModelId).ToString(),
                bool.TrueString,
                "TryApplyProcessAppUserModelId sets canonical AUMID");
            string currentAumid;
            Expect(
                GetCurrentProcessExplicitAppUserModelID(out currentAumid).ToString(),
                "0",
                "GetCurrentProcessExplicitAppUserModelID succeeds");
            Expect(
                currentAumid,
                "com.google.antigravity",
                "Explicit process AUMID matches com.google.antigravity");
        }
        finally
        {
            try { Directory.Delete(tmpRoot, true); } catch { }
        }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] out string appID);

    private static string ResolveRealPwsh()
    {
        var preferred = @"D:\Codex\tools\PowerShell\7.7.0\pwsh.exe";
        if (File.Exists(preferred))
            return preferred;
        var pathEnv = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var entry in pathEnv.Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(entry))
                continue;
            try
            {
                var candidate = Path.Combine(entry.Trim(), "pwsh.exe");
                if (File.Exists(candidate))
                    return candidate;
            }
            catch { }
        }
        return null;
    }

    private static void Expect(string actual, string expected, string scenario)
    {
        if (actual != expected)
            throw new InvalidOperationException(scenario + " (expected=" + expected + ", actual=" + actual + ")");
    }
}
