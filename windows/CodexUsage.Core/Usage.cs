using System.Globalization;
using System.Text.Json;

namespace CodexUsage.Core;

public sealed record QuotaWindow(double? UsedPercent, long? ResetsAt)
{
    public double? RemainingPercent => UsedPercent is >= 0 and <= 100 ? 100 - UsedPercent : null;
    public string RemainingText => RemainingPercent is { } value
        ? Math.Round(value, MidpointRounding.AwayFromZero).ToString(CultureInfo.InvariantCulture) + "%" : "—";

    public string ResetText(DateTimeOffset now)
    {
        if (ResetsAt is not { } seconds) return "重置时间未知";
        DateTimeOffset reset;
        try { reset = DateTimeOffset.FromUnixTimeSeconds(seconds); }
        catch (ArgumentOutOfRangeException) { return "重置时间未知"; }
        if (reset <= now) return "重置时间已到 · 待刷新";
        var minutes = (long)Math.Ceiling((reset - now).TotalMinutes);
        return minutes < 60 ? $"{minutes} 分钟后重置"
            : minutes < 1440 ? $"{minutes / 60} 小时 {minutes % 60} 分后重置"
            : $"{minutes / 1440} 天 {minutes % 1440 / 60} 小时后重置";
    }
}

public sealed record UsageSnapshot(QuotaWindow? FiveHour, QuotaWindow? Weekly, DateTimeOffset ReadAt)
{
    public static UsageSnapshot Parse(JsonElement payload)
    {
        JsonElement bucket;
        if (payload.TryGetProperty("rateLimitsByLimitId", out var buckets) && buckets.ValueKind != JsonValueKind.Null)
        {
            if (buckets.ValueKind != JsonValueKind.Object) throw new JsonException("Invalid quota map");
            if (!buckets.TryGetProperty("codex", out bucket)) return new(null, null, DateTimeOffset.UtcNow);
        }
        else if (!payload.TryGetProperty("rateLimits", out bucket)) return new(null, null, DateTimeOffset.UtcNow);
        if (bucket.ValueKind == JsonValueKind.Null) return new(null, null, DateTimeOffset.UtcNow);
        if (bucket.ValueKind != JsonValueKind.Object) throw new JsonException("Invalid quota bucket");
        if (bucket.TryGetProperty("limitId", out var id) && id.ValueKind == JsonValueKind.String && id.GetString() != "codex")
            return new(null, null, DateTimeOffset.UtcNow);
        QuotaWindow? five = null, week = null;
        foreach (var name in new[] { "primary", "secondary" })
        {
            if (!bucket.TryGetProperty(name, out var window) || window.ValueKind != JsonValueKind.Object) continue;
            if (!window.TryGetProperty("windowDurationMins", out var duration) || duration.ValueKind != JsonValueKind.Number || !duration.TryGetInt32(out var minutes)) continue;
            double? percent = window.TryGetProperty("usedPercent", out var used) && used.ValueKind == JsonValueKind.Number
                && used.TryGetDouble(out var value) && double.IsFinite(value) && value is >= 0 and <= 100 ? value : null;
            long? reset = window.TryGetProperty("resetsAt", out var at) && at.ValueKind == JsonValueKind.Number && at.TryGetInt64(out var epoch) ? epoch : null;
            if (minutes == 300) five ??= new(percent, reset);
            if (minutes == 10080) week ??= new(percent, reset);
        }
        return new(five, week, DateTimeOffset.UtcNow);
    }
}
