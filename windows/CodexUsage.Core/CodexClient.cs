using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json;

namespace CodexUsage.Core;

public sealed class UsageReadException(string message, bool clearSnapshot = false) : Exception(message)
{
    public bool ClearSnapshot { get; } = clearSnapshot;
}

public sealed class CodexClient : IAsyncDisposable
{
    public event Action? AccountChanged;
    private readonly CliCommand? command;
    private readonly Func<CliCommand?> locate;
    public string? Source { get; private set; }
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly SemaphoreSlim writer = new(1, 1);
    private readonly ConcurrentDictionary<long, TaskCompletionSource<JsonElement>> pending = new();
    private readonly CancellationTokenSource lifetime = new();
    private Process? process;
    private bool initialized;
    private long sequence;
    private bool disposed;

    public CodexClient(CliCommand? command = null, Func<CliCommand?>? locate = null)
    {
        this.command = command;
        this.locate = locate ?? (() => CliLocator.Find());
    }

    public async Task ReconnectAsync()
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try { ObjectDisposedException.ThrowIf(disposed, this); Stop(); }
        finally { gate.Release(); }
    }

    public async Task<UsageSnapshot?> ReadAsync(CancellationToken cancellation = default)
    {
        if (!await gate.WaitAsync(0, cancellation).ConfigureAwait(false)) return null;
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (process is null || process.HasExited)
            {
                Stop();
                Source = null;
                var cli = command ?? await Task.Run(locate, cancellation).ConfigureAwait(false)
                    ?? throw new UsageReadException("未找到 Codex CLI。请打开 Codex / ChatGPT 桌面版后刷新，或在菜单中选择 CLI 文件。");
                Source = cli.Source;
                process = new Process { StartInfo = cli.CreateStartInfo() };
                if (!process.Start()) throw new UsageReadException("无法启动 Codex CLI");
                var child = process;
                _ = PumpAsync(child);
                _ = DrainErrorsAsync(child);
            }
            if (!initialized)
            {
                await RequestAsync("initialize", new { clientInfo = new { name = "codex_usage", title = "Codex Usage", version = "0.3.3" } }, cancellation).ConfigureAwait(false);
                await WriteAsync(new { method = "initialized", @params = new { } }).ConfigureAwait(false);
                initialized = true;
            }
            var result = await RequestAsync("account/rateLimits/read", null, cancellation).ConfigureAwait(false);
            var snapshot = UsageSnapshot.Parse(result);
            if (snapshot.FiveHour?.RemainingPercent is null && snapshot.Weekly?.RemainingPercent is null)
                throw new UsageReadException("当前账户未返回 5h / 周额度。请确认桌面版已登录 ChatGPT 账户，或使用菜单中的登录入口。", true);
            return snapshot;
        }
        catch (UsageReadException failure)
        {
            if (failure.ClearSnapshot) Stop(); // Reload CLI-managed login after a sign-in or account change.
            throw;
        }
        catch (Exception error) when (error is IOException or InvalidOperationException or System.ComponentModel.Win32Exception or JsonException or TimeoutException or OperationCanceledException)
        {
            Stop();
            throw new UsageReadException(error is TimeoutException ? "用量请求超时，将自动重试" : "暂时无法读取用量，将自动重试");
        }
        finally { gate.Release(); }
    }

    private async Task<JsonElement> RequestAsync(string method, object? parameters, CancellationToken cancellation)
    {
        var id = Interlocked.Increment(ref sequence);
        var reply = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending[id] = reply;
        try
        {
            await WriteAsync(new { id, method, @params = parameters }).ConfigureAwait(false);
            return await reply.Task.WaitAsync(TimeSpan.FromSeconds(20), cancellation).ConfigureAwait(false);
        }
        finally { pending.TryRemove(id, out _); }
    }

    private async Task WriteAsync(object message)
    {
        await writer.WaitAsync(lifetime.Token).ConfigureAwait(false);
        try
        {
            var input = process?.StandardInput ?? throw new IOException("Disconnected");
            await input.WriteLineAsync(JsonSerializer.Serialize(message)).ConfigureAwait(false);
            await input.FlushAsync(lifetime.Token).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    private async Task PumpAsync(Process child)
    {
        try
        {
            while (await child.StandardOutput.ReadLineAsync(lifetime.Token).ConfigureAwait(false) is { } line)
            {
                if (line.Length > 2_000_000) throw new IOException("Oversized reply");
                JsonDocument document;
                try { document = JsonDocument.Parse(line); } catch (JsonException) { continue; }
                using (document)
                {
                    var message = document.RootElement;
                    if (message.TryGetProperty("id", out var rawId) && rawId.ValueKind == JsonValueKind.Number && rawId.TryGetInt64(out var id) && pending.TryGetValue(id, out var request))
                    {
                        if (message.TryGetProperty("error", out var error))
                        {
                            var text = error.TryGetProperty("message", out var description) ? description.GetString() ?? "" : "";
                            var auth = new[] { "auth", "login", "log in", "logged in", "sign in", "401", "no account", "account not found" }
                                .Any(marker => text.Contains(marker, StringComparison.OrdinalIgnoreCase));
                            request.TrySetException(new UsageReadException(auth ? "本机 Codex 登录不可用。请在桌面版登录 ChatGPT，或使用菜单中的“登录 Codex 账户”。" : "服务暂时无法读取用量，将自动重试", auth));
                        }
                        else if (message.TryGetProperty("result", out var result)) request.TrySetResult(result.Clone());
                        else request.TrySetException(new JsonException("Missing result"));
                    }
                    else if (message.TryGetProperty("method", out var method))
                    {
                        if (message.TryGetProperty("id", out var serverId))
                            await WriteAsync(new { id = serverId.Clone(), error = new { code = -32601, message = "Read-only usage client" } }).ConfigureAwait(false);
                        else if (method.GetString() == "account/updated") AccountChanged?.Invoke();
                    }
                }
            }
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or InvalidOperationException or ObjectDisposedException) { }
        finally
        {
            if (ReferenceEquals(process, child))
                foreach (var request in pending.Values) request.TrySetException(new IOException("Disconnected"));
        }
    }

    private async Task DrainErrorsAsync(Process child)
    {
        try { while (await child.StandardError.ReadLineAsync(lifetime.Token).ConfigureAwait(false) is not null) { } }
        catch (Exception error) when (error is IOException or OperationCanceledException or InvalidOperationException or ObjectDisposedException) { }
    }

    private void Stop()
    {
        var child = process; process = null; initialized = false;
        foreach (var request in pending.Values) request.TrySetException(new IOException("Disconnected"));
        if (child is null) return;
        try { child.StandardInput.Close(); if (!child.HasExited) child.Kill(entireProcessTree: true); }
        catch (Exception error) when (error is IOException or InvalidOperationException or System.ComponentModel.Win32Exception) { }
        child.Dispose();
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed) return;
        lifetime.Cancel();
        await gate.WaitAsync().ConfigureAwait(false);
        try { disposed = true; Stop(); } finally { gate.Release(); }
        lifetime.Dispose();
    }
}
