using System.Diagnostics;

namespace CodexUsage.Core;

public sealed record CliCommand(string FileName, IReadOnlyList<string> PrefixArguments)
{
    public ProcessStartInfo CreateStartInfo()
    {
        var start = new ProcessStartInfo(FileName)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = Path.GetTempPath(),
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8
        };
        foreach (var argument in PrefixArguments) start.ArgumentList.Add(argument);
        start.ArgumentList.Add("app-server"); // The documented default transport is stdio.
        return start;
    }
}

public static class CliLocator
{
    public static CliCommand? Find()
    {
        var configured = Environment.GetEnvironmentVariable("CODEX_USAGE_CLI");
        if (!string.IsNullOrWhiteSpace(configured)) return Resolve(configured);
        foreach (var directory in SearchPath())
            foreach (var name in new[] { "codex.exe", "codex.cmd", "codex" })
                if (Resolve(Path.Combine(directory, name)) is { } command) return command;
        // Inspect only known running app installations, never user documents or auth files.
        if (OperatingSystem.IsWindows())
            foreach (var name in new[] { "Codex", "ChatGPT" })
                foreach (var process in Process.GetProcessesByName(name))
                    using (process)
                        try
                        {
                            var root = Path.GetDirectoryName(process.MainModule?.FileName);
                            if (root is null) continue;
                            foreach (var relative in new[] { "resources/codex.exe", "resources/codex-cli/codex.exe", "codex.exe" })
                                if (Resolve(Path.Combine(root, relative)) is { } command) return command;
                        }
                        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException or IOException) { }
        return null;
    }

    private static IEnumerable<string> SearchPath()
    {
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            yield return directory.Trim('"');
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (!string.IsNullOrEmpty(appData)) yield return Path.Combine(appData, "npm");
    }

    private static CliCommand? Resolve(string path)
    {
        if (!File.Exists(path)) return null;
        var extension = Path.GetExtension(path).ToLowerInvariant();
        if (extension is ".cmd" or ".bat" or ".js")
        {
            // Run npm's JavaScript entrypoint with node directly; never interpolate paths into cmd.exe.
            var js = extension == ".js" ? path : Path.Combine(Path.GetDirectoryName(path)!, "node_modules", "@openai", "codex", "bin", "codex.js");
            if (!File.Exists(js)) return null;
            var node = SearchPath().Select(directory => Path.Combine(directory, OperatingSystem.IsWindows() ? "node.exe" : "node")).FirstOrDefault(File.Exists);
            return node is null ? null : new(node, [js]);
        }
        return new(path, []);
    }
}
