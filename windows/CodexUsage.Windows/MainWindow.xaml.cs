using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using CodexUsage.Core;

namespace CodexUsage.Windows;

public partial class MainWindow : Window
{
    private readonly CodexClient client = new();
    private readonly Preferences preferences;
    private readonly bool selfTest;
    private readonly Func<Rect?>? testHost;
    private readonly DispatcherTimer positionTimer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private readonly DispatcherTimer quotaTimer = new() { Interval = TimeSpan.FromSeconds(30) };
    private readonly DispatcherTimer revealTimer = new(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(1000.0 / 120) };
    private readonly Stopwatch revealClock = new();
    private readonly System.Windows.Forms.NotifyIcon? tray;
    private UsageSnapshot? snapshot;
    private string? error;
    private Point? pressPoint;
    private Point pressOrigin;
    private bool moved, menuOpen, shuttingDown;
    private bool hasPresented;
    internal static readonly TimeSpan RevealDuration = TimeSpan.FromMilliseconds(240);
    internal bool IsRevealing => revealTimer.IsEnabled;
    private ContextMenu? currentMenu;
    internal ContextMenu? DetailsMenu => currentMenu;
    private static readonly Brush Ink = new SolidColorBrush(Color.FromRgb(23, 56, 59));

    public MainWindow() : this(false, null) { }
    internal MainWindow(bool selfTest, Func<Rect?>? testHost)
    {
        this.selfTest = selfTest; this.testHost = testHost;
        preferences = selfTest ? new() : Preferences.Load();
        InitializeComponent();
        SourceInitialized += (_, _) => { NativeWindows.MakeNonActivating(this); Opacity = 0; };
        revealTimer.Tick += (_, _) =>
        {
            var progress = revealClock.Elapsed.TotalMilliseconds / RevealDuration.TotalMilliseconds;
            if (progress >= 1) FinishReveal(); else ApplyReveal(progress);
        };
        Loaded += async (_, _) =>
        {
            if (preferences.Mode == DisplayMode.Free && preferences.FreeX is { } x && preferences.FreeY is { } y) { Left = x; Top = y; }
            positionTimer.Tick += (_, _) => { Position(); Render(); };
            positionTimer.Start();
            if (!selfTest)
            {
                quotaTimer.Tick += async (_, _) => await RefreshAsync();
                quotaTimer.Start(); await RefreshAsync();
            }
            Position();
        };
        client.AccountChanged += () => Dispatcher.BeginInvoke(() => { snapshot = null; Render(); _ = RefreshAsync(); });
        if (!selfTest)
        {
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("CodexUsage.AppIcon.ico")!;
            tray = new System.Windows.Forms.NotifyIcon { Icon = new System.Drawing.Icon(stream), Text = "Codex Usage · 剩余用量", Visible = true };
            tray.MouseClick += (_, _) => Dispatcher.BeginInvoke(ShowDetails);
        }
        Closing += (_, _) => { shuttingDown = true; FinishReveal(); positionTimer.Stop(); quotaTimer.Stop(); tray?.Dispose(); client.DisposeAsync().AsTask().GetAwaiter().GetResult(); };
    }

    private async Task RefreshAsync()
    {
        if (shuttingDown) return;
        try { if (await client.ReadAsync() is { } value) { snapshot = value; error = null; } }
        catch (UsageReadException failure) { error = failure.Message; if (failure.ClearSnapshot) snapshot = null; }
        catch (ObjectDisposedException) { return; }
        Render();
    }

    private void Render()
    {
        if (shuttingDown) return;
        var shortText = snapshot?.FiveHour?.RemainingText ?? "—";
        var weeklyText = snapshot?.Weekly?.RemainingText ?? "—";
        var stale = error is not null || snapshot is null || DateTimeOffset.UtcNow - snapshot.ReadAt > TimeSpan.FromSeconds(90);
        FiveHourValue.Text = shortText; WeeklyValue.Text = weeklyText;
        FiveHourValue.Foreground = WeeklyValue.Foreground = stale ? Brushes.DarkOrange : Ink;
        var now = DateTimeOffset.Now;
        var details = $"剩余用量\n5h：{shortText} · {snapshot?.FiveHour?.ResetText(now) ?? "重置时间未知"}\n本周：{weeklyText} · {snapshot?.Weekly?.ResetText(now) ?? "重置时间未知"}\n{error ?? (snapshot is null ? "正在连接…" : $"更新于 {snapshot.ReadAt.ToLocalTime():HH:mm:ss} · 30 秒刷新")}";
        ToolTip = details;
        if (tray is not null)
        {
            var text = $"Codex Usage · 剩余 5h {shortText} / 周 {weeklyText}{(stale ? "（数据待更新）" : "")}";
            tray.Text = text.Length > 63 ? text[..63] : text;
        }
    }

    internal void Position()
    {
        if (pressPoint is not null || menuOpen) return;
        if (preferences.Mode == DisplayMode.TrayOnly) { HideWidget(); return; }
        if (preferences.Mode == DisplayMode.Free)
        {
            FinishReveal(); Opacity = 1; hasPresented = true;
            if (!IsVisible) Show(); return;
        }
        var host = testHost is null ? NativeWindows.ForegroundCodexBounds(this) : testHost();
        if (host is null || host.Value.Width < 400 || host.Value.Height < 280) { HideWidget(); return; }
        Left = host.Value.Left + 4; Top = host.Value.Bottom - 104 - Height;
        if (!IsVisible || !hasPresented) { StartReveal(); Opacity = 1; hasPresented = true; }
        if (!IsVisible) Show();
    }

    private void HideWidget()
    {
        Hide(); FinishReveal(); hasPresented = false;
    }

    internal void StartReveal(bool? animate = null)
    {
        FinishReveal();
        if (!(animate ?? SystemParameters.ClientAreaAnimation)) return;
        ApplyReveal(0); revealClock.Restart(); revealTimer.Start();
    }

    internal void FinishReveal()
    {
        revealTimer.Stop(); revealClock.Reset(); ApplyReveal(1);
    }

    private void ApplyReveal(double progress)
    {
        var p = Math.Clamp(progress, 0, 1);
        static double EaseOut(double value) => 1 - Math.Pow(1 - Math.Clamp(value, 0, 1), 3);
        static double Smooth(double value) { var t = Math.Clamp(value, 0, 1); return t * t * (3 - 2 * t); }
        var circle = EaseOut(p / 0.5);
        var elongation = EaseOut((p - 0.2) / 0.8);
        // Only the surface changes size. The native window and text canvas keep
        // their final dimensions, so the anchor and glyphs never scale or jump.
        Capsule.Width = 6 + 36 * circle;
        Capsule.Height = 6 + 36 * circle + 36 * elongation;
        Capsule.CornerRadius = new CornerRadius(Math.Min(Capsule.Width / 2, 21 - 3 * elongation));
        Capsule.Opacity = Smooth(p / 0.1);
        QuotaContent.Opacity = Smooth((p - 0.45) / 0.55);
    }

    internal void BeginDrag(Point screenPoint)
    {
        FinishReveal();
        pressPoint = screenPoint; pressOrigin = new Point(Left, Top); moved = false;
    }
    internal void MoveDrag(Point screenPoint)
    {
        if (pressPoint is not { } start) return;
        var delta = screenPoint - start;
        if (!moved && delta.Length <= 3) return;
        moved = true; Left = pressOrigin.X + delta.X; Top = pressOrigin.Y + delta.Y;
    }
    internal void EndDrag()
    {
        if (pressPoint is null) return;
        pressPoint = null;
        if (!moved) { ShowDetails(); return; }
        if (preferences.Mode == DisplayMode.Free)
        {
            preferences.FreeX = Left; preferences.FreeY = Top; if (!selfTest) preferences.Save();
        }
        else Position();
    }
    private Point ScreenPoint(MouseEventArgs args)
    {
        var screen = PointToScreen(args.GetPosition(this));
        return PresentationSource.FromVisual(this)?.CompositionTarget?.TransformFromDevice.Transform(screen) ?? screen;
    }
    private void PointerDown(object sender, MouseButtonEventArgs args)
    {
        BeginDrag(ScreenPoint(args)); ((UIElement)sender).CaptureMouse(); args.Handled = true;
    }
    private void PointerMove(object sender, MouseEventArgs args)
    {
        if (pressPoint is not null && args.LeftButton == MouseButtonState.Pressed) MoveDrag(ScreenPoint(args));
    }
    private void PointerUp(object sender, MouseButtonEventArgs args)
    {
        ((UIElement)sender).ReleaseMouseCapture(); EndDrag(); args.Handled = true;
    }
    private void OpenDetails(object sender, MouseButtonEventArgs args) { ShowDetails(); args.Handled = true; }

    internal void SetMode(DisplayMode mode)
    {
        if (mode == DisplayMode.Free && preferences.Mode != mode && preferences.FreeX is { } x && preferences.FreeY is { } y) { Left = x; Top = y; }
        preferences.Mode = mode; if (!selfTest) preferences.Save(); Position();
    }

    private void ShowDetails()
    {
        FinishReveal();
        if (currentMenu?.IsOpen == true) return;
        var menu = new ContextMenu(); currentMenu = menu;
        var content = new StackPanel { Width = 230, Margin = new Thickness(12, 8, 12, 8) };
        content.Children.Add(new TextBlock { Text = "Codex Usage", FontSize = 14, FontWeight = FontWeights.SemiBold, Foreground = Ink });
        content.Children.Add(new TextBlock { Text = "剩余用量", FontSize = 10, Foreground = Brushes.Gray, Margin = new Thickness(0, 2, 0, 12) });
        AddQuota(content, "5 小时剩余", snapshot?.FiveHour);
        AddQuota(content, "本周剩余", snapshot?.Weekly);
        content.Children.Add(new TextBlock { Text = error ?? (snapshot is null ? "正在连接 Codex CLI…" : $"更新于 {snapshot.ReadAt.ToLocalTime():HH:mm:ss}"),
            FontSize = 10, Foreground = error is null ? Brushes.Gray : Brushes.DarkOrange, TextWrapping = TextWrapping.Wrap });
        menu.Items.Add(content); menu.Items.Add(new Separator());
        AddAction(menu, "立即刷新", () => _ = RefreshAsync());
        AddAction(menu, "贴合左下角（松手回位）", () => SetMode(DisplayMode.Docked), preferences.Mode == DisplayMode.Docked);
        AddAction(menu, "自由悬浮", () => SetMode(DisplayMode.Free), preferences.Mode == DisplayMode.Free);
        AddAction(menu, "仅系统托盘", () => SetMode(DisplayMode.TrayOnly), preferences.Mode == DisplayMode.TrayOnly);
        menu.Items.Add(new Separator()); AddAction(menu, "退出 Codex Usage", () => System.Windows.Application.Current.Shutdown());
        menu.PlacementTarget = IsVisible ? this : null;
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint; menuOpen = true;
        menu.Closed += (_, _) => { menuOpen = false; Position(); };
        menu.IsOpen = true;
    }

    private static void AddQuota(StackPanel parent, string title, QuotaWindow? quota)
    {
        var row = new DockPanel();
        var value = new TextBlock { Text = quota?.RemainingText ?? "—", FontSize = 18, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Right };
        DockPanel.SetDock(value, Dock.Right); row.Children.Add(value);
        row.Children.Add(new TextBlock { Text = title, FontSize = 12, VerticalAlignment = VerticalAlignment.Center }); parent.Children.Add(row);
        parent.Children.Add(new ProgressBar { Minimum = 0, Maximum = 100, Value = quota?.RemainingPercent ?? 0, Height = 3, Margin = new Thickness(0, 5, 0, 5), Foreground = new SolidColorBrush(Color.FromRgb(26, 166, 148)) });
        parent.Children.Add(new TextBlock { Text = quota?.ResetText(DateTimeOffset.Now) ?? "重置时间未知", FontSize = 10, Foreground = Brushes.Gray, Margin = new Thickness(0, 0, 0, 12) });
    }

    private static void AddAction(ContextMenu menu, string title, Action action, bool selected = false)
    {
        var item = new MenuItem { Header = title, IsChecked = selected };
        item.Click += (_, _) => action(); menu.Items.Add(item);
    }

    internal void SeedSelfTest(UsageSnapshot sample)
    {
        if (!selfTest) throw new InvalidOperationException("Only available in explicit self-test mode");
        snapshot = sample; Render();
    }
}
