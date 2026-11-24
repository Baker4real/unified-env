using System;
using System.Collections.Specialized;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class LaunchAntigravity
{
    private const string AppPath = @"D:\Apps\Google.Antigravity\Antigravity.exe";
    private const string AddonsStateDir = @"D:\Codex\tools\antigravity-addons\state";
    private const string AddonsSyncScript = @"D:\Codex\tools\antigravity-addons\Sync-AntigravityAddons.ps1";
    private const string PwshPath = @"D:\Codex\tools\PowerShell\7.7.0\pwsh.exe";
    private const string PwshToolsRoot = @"D:\Codex\tools\PowerShell";
    private const string PwshJunctionFallback = @"C:\Program Files\PowerShell\7\pwsh.exe";
    private const string InternetSettings = @"Software\Microsoft\Windows\CurrentVersion\Internet Settings";

    internal enum ReconcileOutcome
    {
        SkippedMissingAsar,
        FastPathUpToDate,
        SkippedDesktopRunning,
        AppliedPending,
        InvokedColdReconciler,
        SkippedNoReconciler,
        FailedOpen
    }

    [STAThread]
    private static int Main()
    {
        try
        {
            PrepareAddonsForLaunch(AppPath, AddonsStateDir, AddonsSyncScript, PwshPath);

            var start = new ProcessStartInfo(AppPath);
            start.WorkingDirectory = Path.GetDirectoryName(AppPath);
            start.UseShellExecute = false;
            start.EnvironmentVariables.Remove("ELECTRON_RUN_AS_NODE");

            using (var settings = Registry.CurrentUser.OpenSubKey(InternetSettings))
            {
                var enabled = settings != null && object.Equals(settings.GetValue("ProxyEnable"), 1);
                var proxies = enabled ? settings.GetValue("ProxyServer") as string : null;
                ApplyProxy(start.EnvironmentVariables, proxies);
            }

            using (var app = Process.Start(start))
            {
                if (app == null)
                    throw new InvalidOperationException("Windows did not start Antigravity.");
            }
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "Google Antigravity", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    internal static void ApplyProxy(StringDictionary environment, string proxies)
    {
        environment.Remove("HTTP_PROXY");
        environment.Remove("HTTPS_PROXY");
        environment.Remove("ALL_PROXY");
        if (string.IsNullOrWhiteSpace(proxies))
            return;

        string shared = null;
        string http = null;
        string https = null;
        foreach (var item in proxies.Split(';'))
        {
            if (string.IsNullOrWhiteSpace(item))
                continue;
            var assignment = item.Split(new[] { '=' }, 2);
            if (assignment.Length == 1)
                shared = NormalizeProxy(assignment[0]);
            else if (string.Equals(assignment[0].Trim(), "http", StringComparison.OrdinalIgnoreCase))
                http = NormalizeProxy(assignment[1]);
            else if (string.Equals(assignment[0].Trim(), "https", StringComparison.OrdinalIgnoreCase))
                https = NormalizeProxy(assignment[1]);
        }

        http = http ?? shared;
        https = https ?? shared;
        if (http != null)
            environment["HTTP_PROXY"] = http;
        if (https != null)
            environment["HTTPS_PROXY"] = https;
        if (http != null && http == https)
            environment["ALL_PROXY"] = http;
    }

    private static string NormalizeProxy(string input)
    {
        var address = input.Trim();
        if (address.Length == 0)
            return null;
        if (address.IndexOf("://", StringComparison.Ordinal) < 0)
            address = "http://" + address;

        Uri proxy;
        if (!Uri.TryCreate(address, UriKind.Absolute, out proxy) ||
            (proxy.Scheme != Uri.UriSchemeHttp && proxy.Scheme != Uri.UriSchemeHttps) ||
            proxy.Host.Length == 0 || proxy.Port <= 0 || proxy.UserInfo.Length != 0 ||
            proxy.AbsolutePath != "/" || proxy.Query.Length != 0 || proxy.Fragment.Length != 0)
            return null;
        return proxy.GetLeftPart(UriPartial.Authority);
    }

    internal static ReconcileOutcome PrepareAddonsForLaunch(string appPath, string stateDir, string syncScriptPath, string pwshPath)
    {
        var appAsarPath = Path.Combine(Path.GetDirectoryName(appPath), "resources", "app.asar");
        var effectivePwsh = string.IsNullOrWhiteSpace(pwshPath) ? pwshPath : ResolvePwshPath(pwshPath, PwshToolsRoot, PwshJunctionFallback);
        return ReconcileAddonsBeforeLaunch(appAsarPath, stateDir, syncScriptPath, effectivePwsh,
            () => IsDesktopMainRunning(appPath), RunHiddenReconciler);
    }

    internal static string ResolvePwshPath(string preferredPath, string toolsRoot, string fallbackPath)
    {
        if (string.IsNullOrWhiteSpace(preferredPath) || File.Exists(preferredPath))
            return preferredPath;
        try
        {
            if (!string.IsNullOrWhiteSpace(toolsRoot) && Directory.Exists(toolsRoot))
            {
                string bestPath = null;
                Version bestVersion = null;
                foreach (var dir in Directory.GetDirectories(toolsRoot))
                {
                    var candidate = Path.Combine(dir, "pwsh.exe");
                    if (!File.Exists(candidate))
                        continue;
                    Version parsed;
                    if (Version.TryParse(Path.GetFileName(dir), out parsed))
                    {
                        if (bestVersion == null || parsed > bestVersion)
                        {
                            bestVersion = parsed;
                            bestPath = candidate;
                        }
                    }
                    else if (bestPath == null)
                    {
                        bestPath = candidate;
                    }
                }
                if (bestPath != null)
                    return bestPath;
            }
        }
        catch
        {
            // Fall through to compatibility path when directory enumeration fails.
        }
        if (!string.IsNullOrWhiteSpace(fallbackPath) && File.Exists(fallbackPath))
            return fallbackPath;
        return preferredPath;
    }

    internal static ReconcileOutcome ReconcileAddonsBeforeLaunch(
        string appAsarPath,
        string stateDir,
        string syncScriptPath,
        string pwshPath,
        Func<bool> isDesktopRunning,
        Func<string, string, int> runHiddenPwsh)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(appAsarPath) || !File.Exists(appAsarPath))
                return ReconcileOutcome.SkippedMissingAsar;

            var currentSha = ComputeSha256Hex(appAsarPath);
            var resourcesDir = Path.GetDirectoryName(appAsarPath);
            var lsPath = resourcesDir != null ? Path.Combine(resourcesDir, "bin", "language_server.exe") : null;
            var pendingMetaPath = Path.Combine(stateDir, "pending-apply.json");
            var pendingAsarPath = Path.Combine(stateDir, "pending-app.asar");
            var activeMetaPath = Path.Combine(stateDir, "active-build.json");

            if (File.Exists(pendingMetaPath) && File.Exists(pendingAsarPath))
            {
                if (isDesktopRunning())
                    return ReconcileOutcome.SkippedDesktopRunning;

                var pendingJson = File.ReadAllText(pendingMetaPath, Encoding.UTF8);
                var expectedTarget = ReadJsonSha256Field(pendingJson, "replaceTargetSha256")
                    ?? ReadJsonSha256Field(pendingJson, "officialSha256");
                var expectedCombined = ReadJsonSha256Field(pendingJson, "combinedSha256");
                var expectedLsSha = ReadJsonSha256Field(pendingJson, "languageServerSha256");
                var lsMatches = expectedLsSha == null ||
                    (lsPath != null && File.Exists(lsPath) && string.Equals(ComputeSha256Hex(lsPath), expectedLsSha, StringComparison.OrdinalIgnoreCase));

                if (expectedTarget != null &&
                    expectedCombined != null &&
                    lsMatches &&
                    string.Equals(expectedTarget, currentSha, StringComparison.OrdinalIgnoreCase) &&
                    string.Equals(ComputeSha256Hex(pendingAsarPath), expectedCombined, StringComparison.OrdinalIgnoreCase))
                {
                    if (TrySwapAsarAtomically(appAsarPath, pendingAsarPath, expectedCombined))
                    {
                        try
                        {
                            Directory.CreateDirectory(stateDir);
                            var activeTmp = activeMetaPath + "." + Process.GetCurrentProcess().Id + ".tmp";
                            File.Copy(pendingMetaPath, activeTmp, true);
                            if (File.Exists(activeMetaPath))
                                File.Delete(activeMetaPath);
                            File.Move(activeTmp, activeMetaPath);
                            File.Delete(pendingMetaPath);
                            File.Delete(pendingAsarPath);
                        }
                        catch
                        {
                            // Best-effort metadata promotion; app.asar is already swapped.
                        }
                        return ReconcileOutcome.AppliedPending;
                    }
                    return ReconcileOutcome.FailedOpen;
                }
            }

            if (File.Exists(activeMetaPath))
            {
                var activeJson = File.ReadAllText(activeMetaPath, Encoding.UTF8);
                var activeCombined = ReadJsonSha256Field(activeJson, "combinedSha256");
                var activeLsSha = ReadJsonSha256Field(activeJson, "languageServerSha256");
                var lsMatches = activeLsSha == null ||
                    (lsPath != null && File.Exists(lsPath) && string.Equals(ComputeSha256Hex(lsPath), activeLsSha, StringComparison.OrdinalIgnoreCase));
                if (activeCombined != null &&
                    lsMatches &&
                    string.Equals(activeCombined, currentSha, StringComparison.OrdinalIgnoreCase))
                {
                    return ReconcileOutcome.FastPathUpToDate;
                }
            }

            if (isDesktopRunning())
                return ReconcileOutcome.SkippedDesktopRunning;

            if (string.IsNullOrWhiteSpace(syncScriptPath) || string.IsNullOrWhiteSpace(pwshPath) ||
                !File.Exists(syncScriptPath) || !File.Exists(pwshPath))
            {
                return ReconcileOutcome.SkippedNoReconciler;
            }

            runHiddenPwsh(pwshPath, syncScriptPath);
            return ReconcileOutcome.InvokedColdReconciler;
        }
        catch
        {
            return ReconcileOutcome.FailedOpen;
        }
    }

    internal static string ComputeSha256Hex(string filePath)
    {
        using (var sha = SHA256.Create())
        using (var stream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            var hash = sha.ComputeHash(stream);
            var sb = new StringBuilder(hash.Length * 2);
            for (int i = 0; i < hash.Length; i++)
                sb.Append(hash[i].ToString("x2"));
            return sb.ToString();
        }
    }

    internal static string ReadJsonSha256Field(string json, string fieldName)
    {
        if (string.IsNullOrEmpty(json) || string.IsNullOrEmpty(fieldName))
            return null;
        var matches = Regex.Matches(json, "\"" + Regex.Escape(fieldName) + "\"\\s*:\\s*\"([0-9a-fA-F]{64})\"");
        if (matches.Count != 1)
            return null;
        return matches[0].Groups[1].Value.ToLowerInvariant();
    }

    private static bool TrySwapAsarAtomically(string targetAsar, string sourceAsar, string expectedCombinedSha)
    {
        var dir = Path.GetDirectoryName(targetAsar);
        if (string.IsNullOrEmpty(dir))
            return false;
        var token = Process.GetCurrentProcess().Id + "-" + DateTime.UtcNow.Ticks;
        var staged = Path.Combine(dir, ".app.asar.launch-new-" + token + ".tmp");
        var displaced = Path.Combine(dir, ".app.asar.launch-old-" + token + ".tmp");
        try
        {
            File.Copy(sourceAsar, staged, true);
            if (!string.Equals(ComputeSha256Hex(staged), expectedCombinedSha, StringComparison.OrdinalIgnoreCase))
                return false;

            File.Move(targetAsar, displaced);
            try
            {
                File.Move(staged, targetAsar);
                if (!string.Equals(ComputeSha256Hex(targetAsar), expectedCombinedSha, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Swapped app.asar SHA-256 verification failed.");
            }
            catch
            {
                try { if (File.Exists(targetAsar)) File.Delete(targetAsar); } catch { }
                try { if (File.Exists(displaced)) File.Move(displaced, targetAsar); } catch { }
                return false;
            }

            try { if (File.Exists(displaced)) File.Delete(displaced); } catch { }
            return true;
        }
        catch
        {
            return false;
        }
        finally
        {
            try { if (File.Exists(staged)) File.Delete(staged); } catch { }
        }
    }

    private static bool IsDesktopMainRunning(string appPath)
    {
        try
        {
            foreach (var proc in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(appPath)))
            {
                try
                {
                    if (proc.MainWindowHandle != IntPtr.Zero &&
                        proc.MainModule != null &&
                        string.Equals(proc.MainModule.FileName, appPath, StringComparison.OrdinalIgnoreCase))
                    {
                        return true;
                    }
                }
                catch
                {
                    // Ignore processes that exit or deny module inspection.
                }
                finally
                {
                    proc.Dispose();
                }
            }
        }
        catch
        {
            // Ignore process enumeration errors.
        }
        return false;
    }

    internal static int RunHiddenReconciler(string pwshPath, string syncScriptPath)
    {
        var psi = new ProcessStartInfo(pwshPath);
        psi.Arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -File \"" + syncScriptPath + "\" -Mode Apply -Quiet";
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        psi.WorkingDirectory = Path.GetDirectoryName(syncScriptPath) ?? "";
        using (var proc = Process.Start(psi))
        {
            if (proc == null)
                return -1;
            if (!proc.WaitForExit(90000))
            {
                try { proc.Kill(); } catch { }
                return -2;
            }
            return proc.ExitCode;
        }
    }
}
