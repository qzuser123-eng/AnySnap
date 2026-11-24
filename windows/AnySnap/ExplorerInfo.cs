using System.Runtime.InteropServices;

namespace AnySnap;

/// File Explorer: the folder shown in the window and the selected items (full paths).
public static class ExplorerInfo
{
    /// Maps item names shown in the list (extensions may be hidden) to full paths in the folder.
    public static List<string> ResolveNames(string folder, List<string> names)
    {
        var result = new List<string>();
        if (names.Count == 0) return result;
        string[] entries;
        try { entries = Directory.GetFileSystemEntries(folder); } catch { return result; }
        foreach (var name in names)
        {
            var exact = entries.FirstOrDefault(e => Path.GetFileName(e).Equals(name, StringComparison.OrdinalIgnoreCase));
            var match = exact ?? entries.FirstOrDefault(e => Path.GetFileNameWithoutExtension(e).Equals(name, StringComparison.OrdinalIgnoreCase));
            if (match != null && !result.Contains(match)) result.Add(match);
        }
        return result;
    }

    public static (string? folder, List<string> selected) Read(IntPtr hwnd, string windowTitle)
    {
        string? folder = null;
        var selected = new List<string>();
        object? shell = null;
        try
        {
            var t = Type.GetTypeFromProgID("Shell.Application");
            if (t == null) return (null, selected);
            shell = Activator.CreateInstance(t);
            dynamic windows = ((dynamic)shell!).Windows();
            int count = windows.Count;
            dynamic? best = null;
            for (int i = 0; i < count; i++)
            {
                dynamic? w = null;
                try { w = windows.Item(i); } catch { }
                if (w == null) continue;
                long h;
                try { h = (long)w.HWND; } catch { continue; }
                if (h != hwnd.ToInt64()) continue;
                // Windows 11 tabs share one HWND: prefer the tab whose name matches the window title.
                string name = "";
                try { name = (string)w.LocationName; } catch { }
                if (best == null || (!string.IsNullOrEmpty(name) && windowTitle.StartsWith(name, StringComparison.OrdinalIgnoreCase)))
                    best = w;
            }
            if (best == null) return (null, selected);

            dynamic doc = best.Document;
            try { folder = (string)doc.Folder.Self.Path; } catch { }
            try
            {
                dynamic items = doc.SelectedItems();
                int n = items.Count;
                for (int i = 0; i < n && i < 200; i++)
                {
                    try
                    {
                        string p = items.Item(i).Path;
                        if (!string.IsNullOrEmpty(p)) selected.Add(p);
                    }
                    catch { }
                }
            }
            catch { }
            if (folder != null && folder.StartsWith("::", StringComparison.Ordinal)) folder = null; // virtual folders
        }
        catch { }
        finally
        {
            if (shell != null && Marshal.IsComObject(shell)) Marshal.ReleaseComObject(shell);
        }
        return (folder, selected);
    }
}
