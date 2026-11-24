using System.Collections.Specialized;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;

namespace AnySnap;

public enum ClipboardFormat { Auto, Files, Reference, Image }

/// Clipboard formats and "paste into Claude". Clipboard calls must run on an STA thread.
public static class Delivery
{
    static readonly HashSet<string> TerminalProcesses = new(StringComparer.OrdinalIgnoreCase)
    {
        "WindowsTerminal", "cmd", "powershell", "pwsh", "conhost", "OpenConsole", "wt", "alacritty", "wezterm-gui",
        "Hyper", "Tabby", "warp", "mintty", "Code", "Cursor", "Windsurf",
    };

    public static string ReferenceText(SnapshotMeta m)
    {
        var s = "[AnySnap] " + m.AppName;
        if (!string.IsNullOrEmpty(m.WindowTitle)) s += " — " + m.WindowTitle;
        s += "\ncontext: " + m.ContextPath;
        if (m.ScreenshotPath != null) s += "\nscreenshot: " + m.ScreenshotPath;
        return s;
    }

    public static ClipboardFormat Resolve(ClipboardFormat f, string? targetProcess)
    {
        if (f != ClipboardFormat.Auto) return f;
        if (targetProcess != null && TerminalProcesses.Contains(targetProcess)) return ClipboardFormat.Reference;
        return ClipboardFormat.Files;
    }

    public static void Copy(SnapshotMeta m, ClipboardFormat format, string? targetProcess)
    {
        var data = new DataObject();
        switch (Resolve(format, targetProcess))
        {
            case ClipboardFormat.Image when m.ScreenshotPath != null && File.Exists(m.ScreenshotPath):
                var bytes = File.ReadAllBytes(m.ScreenshotPath);
                using (var ms = new MemoryStream(bytes))
                using (var img = new Bitmap(ms))
                {
                    data.SetImage(new Bitmap(img));
                }
                // Chromium/Electron apps (Claude Desktop) prefer the PNG format: keeps quality.
                data.SetData("PNG", false, new MemoryStream(bytes));
                break;
            case ClipboardFormat.Files:
                var files = new StringCollection();
                if (m.ScreenshotPath != null) files.Add(m.ScreenshotPath);
                files.Add(m.ContextPath);
                data.SetFileDropList(files);
                data.SetText(ReferenceText(m));
                break;
            default:
                data.SetText(ReferenceText(m));
                break;
        }
        for (int i = 0; i < 5; i++)
        {
            try
            {
                Clipboard.SetDataObject(data, true, 3, 100);
                return;
            }
            catch (System.Runtime.InteropServices.ExternalException)
            {
                Thread.Sleep(100);
            }
        }
    }

    /// Main window of the Claude desktop app, if it is running.
    public static IntPtr FindClaudeWindow()
    {
        var pids = new HashSet<int>();
        foreach (var p in Process.GetProcessesByName("claude"))
        {
            pids.Add(p.Id);
            p.Dispose();
        }
        if (pids.Count == 0) return IntPtr.Zero;
        IntPtr best = IntPtr.Zero;
        Native.EnumWindows((h, _) =>
        {
            if (!pids.Contains(Native.ProcessId(h))) return true;
            if (!Native.IsWindowVisible(h) && !Native.IsIconic(h)) return true;
            if ((Native.GetWindowLong(h, Native.GWL_EXSTYLE) & Native.WS_EX_TOOLWINDOW) != 0) return true;
            if (Native.GetWindowTextLength(h) == 0) return true;
            best = h;
            return false;
        }, IntPtr.Zero);
        return best;
    }

    /// Waits until the hotkey's modifier keys are released, brings Claude forward and presses Ctrl+V.
    public static bool PasteIntoClaude()
    {
        var hwnd = FindClaudeWindow();
        if (hwnd == IntPtr.Zero) return false;
        var deadline = DateTime.UtcNow.AddSeconds(3);
        while (DateTime.UtcNow < deadline &&
               (Native.IsKeyDown(Native.VK_LCONTROL) || Native.IsKeyDown(Native.VK_RCONTROL) ||
                Native.IsKeyDown(Native.VK_LMENU) || Native.IsKeyDown(Native.VK_RMENU) ||
                Native.IsKeyDown(Native.VK_LSHIFT) || Native.IsKeyDown(Native.VK_RSHIFT) ||
                Native.IsKeyDown(Native.VK_LWIN) || Native.IsKeyDown(Native.VK_RWIN)))
        {
            Thread.Sleep(20);
        }
        if (!Native.ForceForeground(hwnd)) return false;
        Thread.Sleep(250);
        Native.SendCtrlV();
        return true;
    }
}
