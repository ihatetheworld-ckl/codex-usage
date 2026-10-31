using System;
using System.Collections.Generic;
using System.Diagnostics;
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
        var hostAvailable = true;
        var widget = new MainWindow(true, () => hostAvailable ? NativeWindows.Bounds(new WindowInteropHelper(host).Handle, app.MainWindow!) : null);
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
                var capsule = (Border)widget.FindName("Capsule");
                var quotaContent = (Grid)widget.FindName("QuotaContent");
                var fixedSize = new Size(widget.Width, widget.Height);
                var samples = new List<(double Width, double Height, double Opacity)>();
                Check(MainWindow.RevealDuration == TimeSpan.FromMilliseconds(240), "Appearance duration must be 240 ms");
                widget.StartReveal(true);
                Check(capsule.Width == 6 && capsule.Height == 6 && quotaContent.Opacity == 0, "Appearance must start from a dot without text");
                var clock = Stopwatch.StartNew();
                do
                {
                    await Task.Delay(15);
                    widget.UpdateLayout();
                    samples.Add((capsule.Width, capsule.Height, quotaContent.Opacity));
                    var center = capsule.TranslatePoint(new Point(capsule.ActualWidth / 2, capsule.ActualHeight / 2), widget);
                    Check(Math.Abs(center.X - 24) < 1 && Math.Abs(center.Y - 42) < 1, "Appearance center must not drift");
                    Check(new Point(widget.Left, widget.Top) == docked && new Size(widget.Width, widget.Height) == fixedSize, "Appearance must not move or resize the window");
                    Check(quotaContent.Width == 40.6 && quotaContent.Height == 76.6 && quotaContent.RenderTransform.Value.IsIdentity, "Appearance must not stretch text");
                } while (widget.IsRevealing && clock.Elapsed < TimeSpan.FromSeconds(2));
                Check(!widget.IsRevealing && clock.Elapsed.TotalMilliseconds >= 240 && clock.Elapsed.TotalMilliseconds < 1000, "Appearance must finish and stop its timer");
                Check(samples.Any(s => s.Opacity > 0 && s.Opacity < 1), "Text must fade in after expansion begins");
                Check(samples.Zip(samples.Skip(1)).All(pair => pair.First.Width <= pair.Second.Width && pair.First.Height <= pair.Second.Height), "Appearance must expand without bouncing");
                Check(capsule.Width == 42 && capsule.Height == 78 && quotaContent.Opacity == 1, "Completed appearance must restore the original surface");
                widget.StartReveal(true);
                await Task.Delay(35);
                widget.Position();
                Check(capsule.Width > 6, "Normal positioning must not restart an active appearance");
                hostAvailable = false; widget.Position();
                Check(!widget.IsVisible && !widget.IsRevealing, "Switching away must hide the widget and cancel its appearance");
                await Task.Delay(280);
                Check(!widget.IsVisible, "Canceled appearance must not show the widget again");
                hostAvailable = true; widget.Position();
                Check(widget.IsVisible && new Point(widget.Left, widget.Top) == docked, "Returning must reveal at the correct anchor");
                widget.FinishReveal();
                widget.StartReveal(false);
                Check(!widget.IsRevealing && quotaContent.Opacity == 1, "Disabled system animation must show readable content immediately");
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
