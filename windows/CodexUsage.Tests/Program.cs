using System.Text.Json;
using CodexUsage.Core;

if (args.Length > 0 && args[0] == "--fake-codex")
{
    var scenario = args[1]; var log = args[2];
    while (Console.ReadLine() is { } line)
    {
        using var request = JsonDocument.Parse(line);
        var method = request.RootElement.GetProperty("method").GetString()!;
        File.AppendAllText(log, method + "\n");
        if (!request.RootElement.TryGetProperty("id", out var id)) continue;
        if (method == "initialize") Console.WriteLine(JsonSerializer.Serialize(new { id = id.GetInt64(), result = new { } }));
        else if (scenario is "auth" or "signed-out") Console.WriteLine(JsonSerializer.Serialize(new { id = id.GetInt64(), error = new { message = scenario == "auth" ? "401 Unauthorized" : "No account found" } }));
        else
        {
            var result = scenario == "missing" ? "{}" : """{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":27,"windowDurationMins":300},"secondary":{"usedPercent":42,"windowDurationMins":10080}}}}""";
            var wire = $"{{\"id\":{id.GetInt64()},\"result\":{result}}}\n";
            Console.Write(wire[..9]); Console.Out.Flush(); await Task.Delay(15); Console.Write(wire[9..]);
        }
        Console.Out.Flush();
    }
    return;
}

var checks = 0;
void Check(bool condition, string label) { checks++; if (!condition) throw new Exception(label); }
UsageSnapshot Parse(string source) { using var json = JsonDocument.Parse(source); return UsageSnapshot.Parse(json.RootElement); }
var now = DateTimeOffset.FromUnixTimeSeconds(1000);
Check(new QuotaWindow(25, 2000).RemainingPercent == 75, "remaining amount");
Check(new QuotaWindow(null, null).RemainingText == "—", "unknown is not zero");
foreach (var percent in new[] { -1d, 101d, double.NaN, double.PositiveInfinity }) Check(new QuotaWindow(percent, null).RemainingPercent is null, "invalid percent");
Check(new QuotaWindow(100, null).RemainingText == "0%", "exhausted quota");
Check(new QuotaWindow(0, null).RemainingText == "100%", "unused quota");
Check(new QuotaWindow(99.5, null).RemainingText == "1%", "rounding agrees with macOS");
Check(new QuotaWindow(100, 999).ResetText(now) == "重置时间已到 · 待刷新", "do not invent a reset");
Check(new QuotaWindow(100, 1001).ResetText(now) == "1 分钟后重置", "round future time up");
Check(new QuotaWindow(0, long.MaxValue).ResetText(now) == "重置时间未知", "bad epoch");
var swapped = Parse("""{"rateLimits":{"primary":{"usedPercent":21,"windowDurationMins":10080},"secondary":{"usedPercent":3,"windowDurationMins":300}}}""");
Check(swapped.FiveHour?.RemainingPercent == 97 && swapped.Weekly?.RemainingPercent == 79, "identify by window duration");
Check(Parse("""{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":15}}}""").FiveHour is null, "wrong duration");
Check(Parse("""{"rateLimits":{"primary":{"usedPercent":50,"windowDurationMins":300}},"rateLimitsByLimitId":{"other":{}}}""").FiveHour is null, "authoritative multi-bucket map");
Check(Parse("""{"rateLimits":{"limitId":"other","primary":{"usedPercent":1,"windowDurationMins":300}}}""").FiveHour is null, "never use another model's quota");
Check(Parse("""{"rateLimits":{"primary":{"usedPercent":null,"windowDurationMins":300}}}""").FiveHour?.RemainingPercent is null, "missing percentage");
Check(Parse("""{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":null}}}""").FiveHour is null, "unknown duration");
try { Parse("""{"rateLimitsByLimitId":"changed"}"""); Check(false, "malformed map must fail"); } catch (JsonException) { checks++; }

var temporary = Path.Combine(Path.GetTempPath(), "codex-usage-tests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(temporary);
try
{
    var desktop = Path.Combine(temporary, "Desktop App 空格");
    var nestedCli = Path.Combine(desktop, "resources", "codex-cli", "CodexCLI", "bin", "codex.exe");
    Directory.CreateDirectory(Path.GetDirectoryName(nestedCli)!); File.WriteAllText(nestedCli, "fixture");
    var pathDirectory = Path.Combine(temporary, "old-path"); Directory.CreateDirectory(pathDirectory);
    File.WriteAllText(Path.Combine(pathDirectory, "codex.exe"), "older fixture");
    var found = CliLocator.Find(null, [], [desktop], []);
    Check(found?.FileName == nestedCli && found.Source == "桌面版内置 CLI", "desktop-only nested CLI discovery without PATH or npm");
    Check(CliLocator.Find(null, [pathDirectory], [desktop], [])?.FileName == nestedCli, "prefer desktop CLI over an older PATH installation");
    Check(CliLocator.Find(Path.Combine(temporary, "missing.exe"), [pathDirectory], [desktop], []) is null, "an invalid explicit override is not silently ignored");
    Check(CliLocator.Find(nestedCli, [], [], [])?.FileName == nestedCli, "explicit CLI with spaces and non-ASCII path");
    var standalone = Path.Combine(temporary, "Programs", "OpenAI", "Codex", "bin"); Directory.CreateDirectory(standalone);
    File.WriteAllText(Path.Combine(standalone, "codex.exe"), "fixture");
    Check(CliLocator.Find(null, [], [], [standalone])?.FileName == Path.Combine(standalone, "codex.exe"), "standalone install survives a stale GUI PATH");
    var npm = Path.Combine(temporary, "npm directory");
    var js = Path.Combine(npm, "node_modules", "@openai", "codex", "bin", "codex.js");
    Directory.CreateDirectory(Path.GetDirectoryName(js)!); File.WriteAllText(js, "fixture");
    File.WriteAllText(Path.Combine(npm, "codex.cmd"), "fixture"); File.WriteAllText(Path.Combine(npm, "node.exe"), "fixture");
    var nodeCommand = CliLocator.Find(null, [npm], [], []);
    Check(nodeCommand?.FileName == Path.Combine(npm, "node.exe") && nodeCommand.PrefixArguments.SequenceEqual([js]), "npm shim uses adjacent node without cmd interpolation");
    var wireStart = found!.CreateStartInfo();
    Check(wireStart.StandardInputEncoding!.GetPreamble().Length == 0 && wireStart.ArgumentList.Last() == "app-server", "UTF-8 without a BOM on the app-server input");
    var loginStart = nodeCommand!.CreateLoginStartInfo();
    Check(loginStart.UseShellExecute && !loginStart.RedirectStandardOutput && loginStart.ArgumentList.SequenceEqual([js, "login"]), "login is an explicit official CLI action without captured credentials");
    var gui = Path.Combine(temporary, "GUI named Codex"); Directory.CreateDirectory(Path.Combine(gui, "resources"));
    File.WriteAllText(Path.Combine(gui, "codex.exe"), "GUI fixture");
    Check(CliLocator.Find(null, [], [gui], []) is null, "never start the desktop GUI as an app-server CLI");
    var versioned = Path.Combine(temporary, "versioned");
    var versionedCli = Path.Combine(versioned, "app-2.0", "resources", "codex.exe");
    Directory.CreateDirectory(Path.GetDirectoryName(versionedCli)!); File.WriteAllText(versionedCli, "fixture");
    Check(CliLocator.Find(null, [], [versioned], [])?.FileName == versionedCli, "closed app in a versioned installation directory");

    foreach (var scenario in new[] { "normal", "missing", "auth", "signed-out" })
    {
        var log = Path.Combine(temporary, scenario + ".txt");
        var dll = typeof(CliCommand).Assembly.Location;
        var assembly = System.Reflection.Assembly.GetExecutingAssembly().Location;
        var host = Environment.ProcessPath!;
        var prefix = Path.GetFileNameWithoutExtension(host).Equals("dotnet", StringComparison.OrdinalIgnoreCase)
            ? new[] { assembly, "--fake-codex", scenario, log } : new[] { "--fake-codex", scenario, log };
        await using (var client = new CodexClient(new CliCommand(host, prefix)))
        {
            if (scenario is "auth" or "signed-out" or "missing")
            {
                try { await client.ReadAsync(); Check(false, "missing account or quotas must not look like a healthy connection"); }
                catch (UsageReadException error) { Check(error.ClearSnapshot, "clear stale account on auth failure or unavailable quotas"); }
            }
            else
            {
                var result = await client.ReadAsync();
                Check(scenario == "normal" ? result?.FiveHour?.RemainingPercent == 73 && result.Weekly?.RemainingPercent == 58 : result?.FiveHour is null, "fragmented transport reply");
                if (scenario == "normal") { await client.ReadAsync(); checks++; }
                Check(File.ReadAllLines(log).Count(method => method == "initialize") == 1, "automatic refresh reuses one initialized connection");
                await client.ReconnectAsync();
                Check((await client.ReadAsync())?.FiveHour?.RemainingPercent == 73, "explicit reconnection reloads a working CLI connection");
            }
        }
        var methods = File.ReadAllLines(log);
        Check(methods.All(method => method is "initialize" or "initialized" or "account/rateLimits/read"), "read-only protocol boundary");
        Check(methods.Count(method => method == "initialize") == (scenario == "normal" ? 2 : 1), "only an explicit reconnect starts another server");
    }
}
finally { Directory.Delete(temporary, true); }
Console.WriteLine($"PASS: {checks} Windows-core usage and real subprocess checks");
