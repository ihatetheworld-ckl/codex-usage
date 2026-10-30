using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CodexUsage.Core;

namespace CodexUsage.Windows;

internal static class WindowsSmokeTest
{
    public static int Run(string output)
    {
        var app = new System.Windows.Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var host = new Window { Title = "Codex Usage self-test host", Width = 800, Height = 600, Left = 100, Top = 80 };
        var widget = new MainWindow(true, () => NativeWindows.Bounds(new WindowInteropHelper(host).Handle, app.MainWindow!));
        var checks = 0;
        void Check(bool condition, string description)
        {
            checks++; if (!condition) throw new InvalidOperationException(description);
        }
        app.Startup += async (_, _) =>
        {
            try
            {
                host.Show(); widget.Show(); app.MainWindow = widget;
                await Task.Delay(300);
                Check(new WindowInteropHelper(widget).Handle != IntPtr.Zero, "Native WPF widget did not initialize");
                var bounds = NativeWindows.Bounds(new WindowInteropHelper(host).Handle, widget)!.Value;
                var docked = new Point(bounds.Left + 4, bounds.Bottom - 104 - widget.Height);
                Check(new Point(widget.Left, widget.Top) == docked, "Initial docking position");
                widget.SeedSelfTest(new(new(25, DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds()), new(11, DateTimeOffset.UtcNow.AddDays(3).ToUnixTimeSeconds()), DateTimeOffset.UtcNow));
                var start = new Point(widget.Left + 24, widget.Top + 42);
                widget.BeginDrag(start); widget.MoveDrag(new Point(start.X + 100, start.Y + 50));
                await Task.Delay(300); // The normal position timer must not interrupt the held drag.
                Check(widget.Left == docked.X + 100 && widget.Top == docked.Y + 50, "Held drag moved or snapped prematurely");
                widget.EndDrag(); Check(new Point(widget.Left, widget.Top) == docked, "Docked release did not snap back");
                widget.SetMode(DisplayMode.Free);
                widget.BeginDrag(start); widget.MoveDrag(new Point(start.X + 75, start.Y + 35)); widget.EndDrag();
                var free = new Point(widget.Left, widget.Top);
                Check(free == new Point(docked.X + 75, docked.Y + 35), "Free drag did not remain in place");
                widget.SetMode(DisplayMode.Docked); widget.SetMode(DisplayMode.Free);
                Check(new Point(widget.Left, widget.Top) == free, "Free position was lost across modes");
                widget.BeginDrag(new Point(widget.Left + 24, widget.Top + 42)); widget.EndDrag();
                await Task.Delay(200);
                var menu = widget.DetailsMenu!;
                Check(menu.IsOpen, "Click did not open details");
                var content = menu.Items.OfType<StackPanel>().Single();
                Check(content.ActualHeight > 100, "Details are blank or collapsed");
                Check(content.Children.OfType<DockPanel>().SelectMany(row => row.Children.OfType<TextBlock>()).Any(label => label.Text == "75%"), "Remaining quota is absent from details");
                menu.IsOpen = false;
                var bitmap = new RenderTargetBitmap(96, 168, 192, 192, PixelFormats.Pbgra32);
                widget.UpdateLayout(); bitmap.Render(widget);
                var pixels = new byte[96 * 168 * 4]; bitmap.CopyPixels(pixels, 96 * 4, 0);
                Check(pixels[3] == 0 && pixels[(96 * 168 - 1) * 4 + 3] == 0, "Window corners have an opaque background");
                var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                var directory = Path.GetDirectoryName(Path.GetFullPath(output))!; Directory.CreateDirectory(directory);
                using (var image = File.Create(Path.Combine(directory, "windows-widget-preview.png"))) encoder.Save(image);
                File.WriteAllText(output, JsonSerializer.Serialize(new { passed = true, checks, operatingSystem = Environment.OSVersion.ToString(),
                    note = "Synthetic usage and a native test host; no real account credentials or Codex window were used." }));
                widget.Close(); host.Close(); app.Shutdown(0);
            }
            catch (Exception failure)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output))!);
                File.WriteAllText(output, JsonSerializer.Serialize(new { passed = false, checks, error = failure.ToString() }));
                widget.Close(); host.Close(); app.Shutdown(1);
            }
        };
        return app.Run();
    }
}
