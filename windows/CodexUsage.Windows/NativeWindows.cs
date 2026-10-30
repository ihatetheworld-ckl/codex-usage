using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace CodexUsage.Windows;

internal static class NativeWindows
{
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr window, out NativeRect rect);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsIconic(IntPtr window);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out NativeRect rect, int size);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr style);

    public static void MakeNonActivating(Window window)
    {
        var handle = new WindowInteropHelper(window).Handle;
        var style = GetWindowLongPtr(handle, -20).ToInt64();
        SetWindowLongPtr(handle, -20, new IntPtr(style | 0x08000000L | 0x80L)); // NOACTIVATE | TOOLWINDOW
    }

    public static Rect? ForegroundCodexBounds(Window widget)
    {
        var handle = GetForegroundWindow();
        if (handle == IntPtr.Zero || IsIconic(handle)) return null;
        GetWindowThreadProcessId(handle, out var id);
        try
        {
            using var process = Process.GetProcessById((int)id);
            if (!process.ProcessName.Equals("Codex", StringComparison.OrdinalIgnoreCase) &&
                !process.ProcessName.Equals("ChatGPT", StringComparison.OrdinalIgnoreCase)) return null;
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { return null; }
        return Bounds(handle, widget);
    }

    public static Rect? Bounds(IntPtr handle, Window widget)
    {
        if (DwmGetWindowAttribute(handle, 9, out var rect, Marshal.SizeOf<NativeRect>()) != 0 && !GetWindowRect(handle, out rect)) return null;
        var source = PresentationSource.FromVisual(widget);
        var transform = source?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var topLeft = transform.Transform(new Point(rect.Left, rect.Top));
        var bottomRight = transform.Transform(new Point(rect.Right, rect.Bottom));
        return new Rect(topLeft, bottomRight);
    }
}
