using System;
using System.IO;
using System.Text.Json;

namespace CodexUsage.Windows;

internal enum DisplayMode { Docked, Free, TrayOnly }

internal sealed class Preferences
{
    public DisplayMode Mode { get; set; } = DisplayMode.Docked;
    public double? FreeX { get; set; }
    public double? FreeY { get; set; }
    private static string FileName => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexUsage", "settings.json");
    public static Preferences Load()
    {
        try { return JsonSerializer.Deserialize<Preferences>(File.ReadAllText(FileName)) ?? new(); }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { return new(); }
    }
    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FileName)!);
            var temporary = FileName + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(this));
            File.Move(temporary, FileName, true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
}
