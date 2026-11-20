using System;
using System.Collections.Specialized;

internal static class TestLauncher
{
    private static void Main()
    {
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
        Console.WriteLine("Antigravity launcher fixture passed.");
    }

    private static void Expect(string actual, string expected, string scenario)
    {
        if (actual != expected)
            throw new InvalidOperationException(scenario);
    }
}
