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
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly SemaphoreSlim writer = new(1, 1);
    private readonly ConcurrentDictionary<long, TaskCompletionSource<JsonElement>> pending = new();
    private readonly CancellationTokenSource lifetime = new();
    private Process? process;
    private bool initialized;
    private long sequence;
    private bool disposed;

    public CodexClient(CliCommand? command = null) { this.command = command; }

    public async Task<UsageSnapshot?> ReadAsync(CancellationToken cancellation = default)
    {
        if (!await gate.WaitAsync(0, cancellation).ConfigureAwait(false)) return null;
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (process is null || process.HasExited)
            {
                Stop();
                var cli = command ?? CliLocator.Find() ?? throw new UsageReadException("未找到 Codex CLI，请安装后运行 codex login");
                process = new Process { StartInfo = cli.CreateStartInfo() };
                if (!process.Start()) throw new UsageReadException("无法启动 Codex CLI");
                var child = process;
                _ = PumpAsync(child);
                _ = DrainErrorsAsync(child);
            }
            if (!initialized)
            {
                await RequestAsync("initialize", new { clientInfo = new { name = "codex_usage", title = "Codex Usage", version = "0.3.1" } }, cancellation).ConfigureAwait(false);
                await WriteAsync(new { method = "initialized", @params = new { } }).ConfigureAwait(false);
                initialized = true;
            }
            var result = await RequestAsync("account/rateLimits/read", null, cancellation).ConfigureAwait(false);
            return UsageSnapshot.Parse(result);
        }
        catch (UsageReadException) { throw; }
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
                            var auth = text.Contains("auth", StringComparison.OrdinalIgnoreCase) || text.Contains("login", StringComparison.OrdinalIgnoreCase) || text.Contains("401", StringComparison.Ordinal);
                            request.TrySetException(new UsageReadException(auth ? "登录已失效，请运行 codex login" : "服务暂时无法读取用量，将自动重试", auth));
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
