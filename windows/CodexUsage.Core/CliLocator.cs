using System.Diagnostics;

namespace CodexUsage.Core;

public sealed record CliCommand(string FileName, IReadOnlyList<string> PrefixArguments, string Source = "指定的 Codex CLI")
{
    public ProcessStartInfo CreateStartInfo()
    {
        var start = new ProcessStartInfo(FileName)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = Path.GetTempPath(),
            StandardInputEncoding = new System.Text.UTF8Encoding(false),
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8
        };
        foreach (var argument in PrefixArguments) start.ArgumentList.Add(argument);
        start.ArgumentList.Add("app-server"); // The documented default transport is stdio.
        return start;
    }

    public ProcessStartInfo CreateLoginStartInfo()
    {
        var start = new ProcessStartInfo(FileName) { UseShellExecute = true, WorkingDirectory = Path.GetTempPath() };
        foreach (var argument in PrefixArguments) start.ArgumentList.Add(argument);
        start.ArgumentList.Add("login");
        return start;
    }
}

public static class CliLocator
{
    public static CliCommand? Find(string? savedPath = null)
    {
        var configured = Environment.GetEnvironmentVariable("CODEX_USAGE_CLI");
        return Find(string.IsNullOrWhiteSpace(configured) ? savedPath : configured,
            SearchPath().ToArray(), DesktopRoots(), StandaloneDirectories());
    }

    // The explicit inputs also allow discovery regressions with real temporary layouts,
    // without changing the user's PATH, installed desktop app, or authentication.
    public static CliCommand? Find(string? configured, IEnumerable<string> pathDirectories,
        IEnumerable<string> desktopRoots, IEnumerable<string> standaloneDirectories)
    {
        var paths = pathDirectories.ToArray();
        if (!string.IsNullOrWhiteSpace(configured)) return Resolve(configured, paths, "指定的 Codex CLI");
        // Prefer the running desktop's own binary over a possibly older npm installation.
        foreach (var root in desktopRoots.Distinct(StringComparer.OrdinalIgnoreCase))
            foreach (var path in DesktopCandidates(root))
                if (Resolve(path, paths, "桌面版内置 CLI") is { } command) return command;
        foreach (var directory in standaloneDirectories)
            if (Resolve(Path.Combine(directory, "codex.exe"), paths, "独立安装的 Codex CLI") is { } command) return command;
        foreach (var directory in paths)
            foreach (var name in new[] { "codex.exe", "codex.cmd", "codex" })
                if (Resolve(Path.Combine(directory, name), paths, "PATH / npm 的 Codex CLI") is { } command) return command;
        return null;
    }

    private static IEnumerable<string> DesktopRoots()
    {
        if (!OperatingSystem.IsWindows()) yield break;
        // Only inspect known application processes and conventional installation roots.
        foreach (var name in new[] { "ChatGPT", "Codex" })
            foreach (var process in Process.GetProcessesByName(name))
                using (process)
                {
                    string? root = null;
                    try { root = Path.GetDirectoryName(process.MainModule?.FileName); }
                    catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException or IOException) { }
                    if (root is not null) yield return root;
                }
        foreach (var parent in new[] {
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles) })
        {
            if (string.IsNullOrEmpty(parent)) continue;
            foreach (var relative in new[] { "Programs/ChatGPT", "Programs/Codex", "Programs/OpenAI/ChatGPT", "Programs/OpenAI/Codex", "OpenAI/ChatGPT", "OpenAI/Codex", "ChatGPT", "Codex" })
                yield return Path.Combine(parent, relative);
        }
    }

    private static IEnumerable<string> StandaloneDirectories()
    {
        if (Environment.GetEnvironmentVariable("CODEX_INSTALL_DIR") is { Length: > 0 } configured) yield return configured;
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (!string.IsNullOrEmpty(local)) yield return Path.Combine(local, "Programs", "OpenAI", "Codex", "bin");
    }

    private static IEnumerable<string> DesktopCandidates(string root)
    {
        foreach (var relative in new[] {
            "resources/codex.exe", "resources/codex-cli/codex.exe",
            "resources/codex-cli/CodexCLI/codex.exe", "resources/codex-cli/CodexCLI/bin/codex.exe",
            "resources/codex-cli/bin/codex.exe", "app/resources/codex.exe", "bin/codex.exe" })
            yield return Path.Combine(root, relative);
        // Limit traversal to application resources and versioned app folders. Never scan
        // a drive, user documents, .codex/auth.json, or the OS credential store.
        var queue = new Queue<(string Path, int Depth)>();
        queue.Enqueue((root, 0));
        var visited = 0;
        while (queue.TryDequeue(out var current) && visited++ < 200)
        {
            yield return Path.Combine(current.Path, "codex.exe");
            if (current.Depth >= 6) continue;
            string[] children;
            try { children = Directory.GetDirectories(current.Path); }
            catch (Exception error) when (error is UnauthorizedAccessException or IOException) { continue; }
            foreach (var child in children.Order(StringComparer.OrdinalIgnoreCase))
            {
                var name = Path.GetFileName(child);
                if (current.Depth == 0 && !(name.Equals("resources", StringComparison.OrdinalIgnoreCase) ||
                    name.Equals("bin", StringComparison.OrdinalIgnoreCase) || name.StartsWith("codex", StringComparison.OrdinalIgnoreCase) ||
                    name.Equals("app", StringComparison.OrdinalIgnoreCase) || name.StartsWith("app-", StringComparison.OrdinalIgnoreCase))) continue;
                try { if ((File.GetAttributes(child) & FileAttributes.ReparsePoint) != 0) continue; }
                catch (Exception error) when (error is UnauthorizedAccessException or IOException) { continue; }
                queue.Enqueue((child, current.Depth + 1));
            }
        }
    }

    private static IEnumerable<string> SearchPath()
    {
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            yield return directory.Trim('"');
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (!string.IsNullOrEmpty(appData)) yield return Path.Combine(appData, "npm");
    }

    private static CliCommand? Resolve(string path, IReadOnlyList<string> paths, string source)
    {
        if (!File.Exists(path)) return null;
        var extension = Path.GetExtension(path).ToLowerInvariant();
        if (extension is ".cmd" or ".bat" or ".js")
        {
            // Run npm's JavaScript entrypoint with node directly; never interpolate paths into cmd.exe.
            var js = extension == ".js" ? path : Path.Combine(Path.GetDirectoryName(path)!, "node_modules", "@openai", "codex", "bin", "codex.js");
            if (!File.Exists(js)) return null;
            var node = new[] { Path.GetDirectoryName(path)! }.Concat(paths)
                .SelectMany(directory => new[] { Path.Combine(directory, "node.exe"), Path.Combine(directory, "node") }).FirstOrDefault(File.Exists);
            return node is null ? null : new(node, [js], source);
        }
        // Avoid launching the desktop GUI itself when it is named Codex.exe.
        if (Path.GetFileName(path).Equals("codex.exe", StringComparison.OrdinalIgnoreCase) &&
            Directory.Exists(Path.Combine(Path.GetDirectoryName(path)!, "resources")) &&
            !File.Exists(Path.Combine(Path.GetDirectoryName(path)!, "ChatGPT.exe"))) return null;
        return new(path, [], source);
    }
}
