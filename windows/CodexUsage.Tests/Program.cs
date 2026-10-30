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
        else if (scenario == "auth") Console.WriteLine(JsonSerializer.Serialize(new { id = id.GetInt64(), error = new { message = "401 Unauthorized" } }));
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
    foreach (var scenario in new[] { "normal", "missing", "auth" })
    {
        var log = Path.Combine(temporary, scenario + ".txt");
        var dll = typeof(CliCommand).Assembly.Location;
        var assembly = System.Reflection.Assembly.GetExecutingAssembly().Location;
        var host = Environment.ProcessPath!;
        var prefix = Path.GetFileNameWithoutExtension(host).Equals("dotnet", StringComparison.OrdinalIgnoreCase)
            ? new[] { assembly, "--fake-codex", scenario, log } : new[] { "--fake-codex", scenario, log };
        await using (var client = new CodexClient(new CliCommand(host, prefix)))
        {
            if (scenario == "auth")
            {
                try { await client.ReadAsync(); Check(false, "auth must fail"); }
                catch (UsageReadException error) { Check(error.ClearSnapshot, "clear stale account on auth failure"); }
            }
            else
            {
                var result = await client.ReadAsync();
                Check(scenario == "normal" ? result?.FiveHour?.RemainingPercent == 73 && result.Weekly?.RemainingPercent == 58 : result?.FiveHour is null, "fragmented transport reply");
                if (scenario == "normal") { await client.ReadAsync(); checks++; }
            }
        }
        var methods = File.ReadAllLines(log);
        Check(methods.All(method => method is "initialize" or "initialized" or "account/rateLimits/read"), "read-only protocol boundary");
        Check(methods.Count(method => method == "initialize") == 1, "reuse one connection");
    }
}
finally { Directory.Delete(temporary, true); }
Console.WriteLine($"PASS: {checks} Windows-core usage and real subprocess checks");
