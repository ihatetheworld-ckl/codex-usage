using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using CodexUsage.Core;

namespace CodexUsage.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--probe") return ProbeAsync(args.Length > 1 ? args[1] : null).GetAwaiter().GetResult();
        if (args.Length > 0 && args[0] == "--self-test") return WindowsSmokeTest.Run(args.Length > 1 ? args[1] : "windows-smoke.json");
        using var singleInstance = new Mutex(true, "Local\\CodexUsage.Widget", out var created);
        if (!created) return 0;
        var app = new System.Windows.Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        return app.Run(new MainWindow());
    }

    private static async Task<int> ProbeAsync(string? output)
    {
        await using var client = new CodexClient();
        try
        {
            var usage = await client.ReadAsync() ?? throw new UsageReadException("No response");
            var json = JsonSerializer.Serialize(new { fiveHourRemainingPercent = usage.FiveHour?.RemainingPercent,
                weeklyRemainingPercent = usage.Weekly?.RemainingPercent, fiveHourResetsAt = usage.FiveHour?.ResetsAt,
                weeklyResetsAt = usage.Weekly?.ResetsAt });
            if (output is null) Console.WriteLine(json); else await File.WriteAllTextAsync(output, json);
            return usage.FiveHour?.RemainingPercent is not null && usage.Weekly?.RemainingPercent is not null ? 0 : 2;
        }
        catch (UsageReadException failure)
        {
            if (output is not null) await File.WriteAllTextAsync(output, JsonSerializer.Serialize(new { error = failure.Message }));
            return 1;
        }
    }
}
