using System.Diagnostics;
using System.Runtime.InteropServices;

namespace AnySnap;

public sealed class TargetWindow
{
    public IntPtr Hwnd;
    public int Pid;
    public string ProcessName = "";
    public string? ExePath;
    public string AppName = "";
    public string Title = "";
}

/// Picks the window to capture: the foreground window, skipping our own windows and
/// the app that launched us (e.g. Claude Desktop when called over MCP, or the terminal).
public static class WindowFinder
{
    static readonly HashSet<string> IgnoredClasses = new(StringComparer.OrdinalIgnoreCase)
    {
        "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Progman", "WorkerW", "NotifyIconOverflowWindow",
        "Windows.UI.Core.CoreWindow", "XamlExplorerHostIslandWindow", "TopLevelWindowForOverflowXamlIsland",
        "ForegroundStaging", "MultitaskingViewFrame", "TaskListThumbnailWnd",
    };

    public static TargetWindow? Find(string? appName, ISet<int> excludePids, IntPtr preferred = default)
    {
        if (preferred != IntPtr.Zero && IsCandidate(preferred, excludePids) && Matches(preferred, appName))
            return Describe(preferred);

        var fg = Native.GetForegroundWindow();
        if (fg != IntPtr.Zero)
        {
            var root = Native.GetAncestor(fg, Native.GA_ROOTOWNER);
            if (root != IntPtr.Zero && IsCandidate(root, excludePids) && Matches(root, appName)) return Describe(root);
            if (IsCandidate(fg, excludePids) && Matches(fg, appName)) return Describe(fg);
        }

        // EnumWindows walks top-level windows in Z order (front to back).
        IntPtr found = IntPtr.Zero;
        Native.EnumWindows((h, _) =>
        {
            if (IsCandidate(h, excludePids) && Matches(h, appName)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found == IntPtr.Zero ? null : Describe(found);
    }

    public static bool IsCandidate(IntPtr h, ISet<int> excludePids)
    {
        if (h == IntPtr.Zero || !Native.IsWindowVisible(h) || Native.IsCloaked(h)) return false;
        if (IgnoredClasses.Contains(Native.ClassName(h))) return false;
        int ex = Native.GetWindowLong(h, Native.GWL_EXSTYLE);
        if ((ex & Native.WS_EX_TOOLWINDOW) != 0) return false;
        int pid = Native.ProcessId(h);
        if (pid == Environment.ProcessId || excludePids.Contains(pid)) return false;
        var r = Native.FrameBounds(h);
        if (r.Width < 80 || r.Height < 50) return false;
        if (Native.GetWindowTextLength(h) == 0 && (r.Width < 300 || r.Height < 200)) return false;
        return true;
    }

    static bool Matches(IntPtr h, string? appName)
    {
        if (string.IsNullOrWhiteSpace(appName)) return true;
        var want = appName.Trim();
        if (want.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) want = want[..^4];
        var t = Describe(h);
        return t.ProcessName.Equals(want, StringComparison.OrdinalIgnoreCase)
            || t.AppName.Equals(want, StringComparison.OrdinalIgnoreCase)
            || t.AppName.Contains(want, StringComparison.OrdinalIgnoreCase)
            || t.Title.Contains(want, StringComparison.OrdinalIgnoreCase);
    }

    public static TargetWindow Describe(IntPtr h)
    {
        var t = new TargetWindow { Hwnd = h, Pid = Native.ProcessId(h), Title = Native.WindowText(h) };
        try
        {
            using var p = Process.GetProcessById(t.Pid);
            t.ProcessName = p.ProcessName;
            try { t.ExePath = p.MainModule?.FileName; } catch { }
        }
        catch { }
        t.AppName = FriendlyName(t);
        return t;
    }

    static string FriendlyName(TargetWindow t)
    {
        if (t.ExePath != null)
        {
            try
            {
                var vi = FileVersionInfo.GetVersionInfo(t.ExePath);
                var d = vi.FileDescription?.Trim();
                if (!string.IsNullOrEmpty(d) && d.Length <= 60) return d;
                var pn = vi.ProductName?.Trim();
                if (!string.IsNullOrEmpty(pn) && pn.Length <= 60) return pn;
            }
            catch { }
        }
        return string.IsNullOrEmpty(t.ProcessName) ? "Unknown" : t.ProcessName;
    }

    // ---- host process detection ----

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_BASIC_INFORMATION
    {
        public IntPtr Reserved1, PebBaseAddress, Reserved2_0, Reserved2_1, UniqueProcessId, InheritedFromUniqueProcessId;
    }

    [DllImport("ntdll.dll")]
    static extern int NtQueryInformationProcess(IntPtr processHandle, int processInformationClass,
        ref PROCESS_BASIC_INFORMATION processInformation, int processInformationLength, out int returnLength);

    static int? ParentPid(int pid)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            var pbi = new PROCESS_BASIC_INFORMATION();
            if (NtQueryInformationProcess(p.Handle, 0, ref pbi, Marshal.SizeOf(pbi), out _) != 0) return null;
            int ppid = pbi.InheritedFromUniqueProcessId.ToInt32();
            return ppid > 4 ? ppid : null;
        }
        catch { return null; }
    }

    /// Our ancestor processes (terminal, shell, Claude Desktop, ...). Their windows are
    /// skipped so "capture" returns the window the user was looking at, not the caller.
    public static HashSet<int> AncestorPids()
    {
        var set = new HashSet<int>();
        int? pid = ParentPid(Environment.ProcessId);
        for (int i = 0; i < 16 && pid != null && set.Add(pid.Value); i++)
        {
            // Stop at Explorer: everything launched from the desktop has it as an ancestor.
            try
            {
                using var p = Process.GetProcessById(pid.Value);
                if (p.ProcessName.Equals("explorer", StringComparison.OrdinalIgnoreCase)) { set.Remove(pid.Value); break; }
            }
            catch { break; }
            pid = ParentPid(pid.Value);
        }
        return set;
    }
}
