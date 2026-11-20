using System;
using System.Collections.Specialized;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class LaunchAntigravity
{
    private const string AppPath = @"D:\Apps\Google.Antigravity\Antigravity.exe";
    private const string InternetSettings = @"Software\Microsoft\Windows\CurrentVersion\Internet Settings";

    [STAThread]
    private static int Main()
    {
        try
        {
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
}
