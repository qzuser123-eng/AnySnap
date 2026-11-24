using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AnySnap;

/// Metadata written next to every snapshot as meta.json (same fields as the macOS version).
public sealed class SnapshotMeta
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("createdAt")] public DateTimeOffset CreatedAt { get; set; }
    [JsonPropertyName("appName")] public string AppName { get; set; } = "";
    /// Executable path on Windows (bundle id on macOS)
    [JsonPropertyName("bundleID")] public string? BundleID { get; set; }
    [JsonPropertyName("pid")] public int Pid { get; set; }
    [JsonPropertyName("windowTitle")] public string? WindowTitle { get; set; }
    [JsonPropertyName("url")] public string? Url { get; set; }
    /// x, y, width, height in screen pixels
    [JsonPropertyName("frame")] public double[]? Frame { get; set; }
    [JsonPropertyName("screenshotPath")] public string? ScreenshotPath { get; set; }
    [JsonPropertyName("contextPath")] public string ContextPath { get; set; } = "";
    [JsonPropertyName("textCharacters")] public int TextCharacters { get; set; }
    [JsonPropertyName("textTruncated")] public bool TextTruncated { get; set; }
    [JsonPropertyName("folderPath")] public string? FolderPath { get; set; }
    [JsonPropertyName("selectedPaths")] public List<string>? SelectedPaths { get; set; }
    [JsonPropertyName("details")] public List<string>? Details { get; set; }
    [JsonPropertyName("browserTabs")] public List<string>? BrowserTabs { get; set; }
    /// "accessibility" (UI Automation, incl. off-screen) or "ocr" (visible text only)
    [JsonPropertyName("textSource")] public string? TextSource { get; set; }
    [JsonPropertyName("warnings")] public List<string> Warnings { get; set; } = new();
}

/// Snapshots live in %LOCALAPPDATA%\AnySnap\snapshots\<id>\
///   screenshot.png – window image
///   context.md     – app/window info + window text (what agents read)
///   meta.json      – SnapshotMeta
/// Override the location with the ANYSNAP_HOME environment variable.
public static class SnapshotStore
{
    static readonly JsonSerializerOptions JsonOpts = new() { WriteIndented = true };

    public static string AppDataDir
    {
        get
        {
            var env = Environment.GetEnvironmentVariable("ANYSNAP_HOME");
            if (!string.IsNullOrWhiteSpace(env))
                return Path.GetFullPath(Path.Combine(Environment.ExpandEnvironmentVariables(env), ".."));
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AnySnap");
        }
    }

    public static string Root
    {
        get
        {
            var env = Environment.GetEnvironmentVariable("ANYSNAP_HOME");
            if (!string.IsNullOrWhiteSpace(env)) return Path.GetFullPath(Environment.ExpandEnvironmentVariables(env));
            return Path.Combine(AppDataDir, "snapshots");
        }
    }

    public static string Directory(string id) => Path.Combine(Root, id);

    public static string NewId()
    {
        return DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) + "-" +
               Guid.NewGuid().ToString("N")[..6];
    }

    public static string CreateDirectory(string id)
    {
        var dir = Directory(id);
        System.IO.Directory.CreateDirectory(dir);
        return dir;
    }

    public static void Save(SnapshotMeta meta, string context)
    {
        var dir = CreateDirectory(meta.Id);
        File.WriteAllText(Path.Combine(dir, "context.md"), context, new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(dir, "meta.json"), JsonSerializer.Serialize(meta, JsonOpts), new UTF8Encoding(false));
        try { File.WriteAllText(Path.Combine(Root, "latest"), meta.Id); } catch { }
    }

    public static string Json(SnapshotMeta meta) => JsonSerializer.Serialize(meta, JsonOpts);

    public static SnapshotMeta? Load(string id)
    {
        if (string.IsNullOrWhiteSpace(id) || id.Contains("..") || id.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) return null;
        var p = Path.Combine(Directory(id), "meta.json");
        if (!File.Exists(p)) return null;
        try { return JsonSerializer.Deserialize<SnapshotMeta>(File.ReadAllText(p)); }
        catch { return null; }
    }

    public static List<string> AllIds()
    {
        if (!System.IO.Directory.Exists(Root)) return new();
        return System.IO.Directory.GetDirectories(Root)
            .Select(Path.GetFileName)
            .Where(n => n != null && File.Exists(Path.Combine(Root, n!, "meta.json")))
            .Select(n => n!)
            .OrderByDescending(n => n, StringComparer.Ordinal)
            .ToList();
    }

    public static List<SnapshotMeta> List(int limit)
    {
        var result = new List<SnapshotMeta>();
        foreach (var id in AllIds())
        {
            if (result.Count >= limit) break;
            var m = Load(id);
            if (m != null) result.Add(m);
        }
        return result;
    }

    public static SnapshotMeta? Latest() => List(1).FirstOrDefault();

    public static string Context(SnapshotMeta m)
    {
        try { return File.ReadAllText(m.ContextPath); } catch { return ""; }
    }

    // ---- retention ----

    static string RetentionFile => Path.Combine(AppDataDir, "retention-days");

    /// Days to keep snapshots; 0 = forever. Default 3.
    public static int RetentionDays
    {
        get
        {
            try { return int.Parse(File.ReadAllText(RetentionFile).Trim(), CultureInfo.InvariantCulture); }
            catch { return 3; }
        }
        set
        {
            System.IO.Directory.CreateDirectory(AppDataDir);
            File.WriteAllText(RetentionFile, value.ToString(CultureInfo.InvariantCulture));
        }
    }

    public static int PruneExpired()
    {
        int days = RetentionDays;
        if (days <= 0) return 0;
        var cutoff = DateTimeOffset.Now.AddDays(-days);
        int removed = 0;
        foreach (var id in AllIds())
        {
            var m = Load(id);
            if (m != null && m.CreatedAt < cutoff)
            {
                try { System.IO.Directory.Delete(Directory(id), true); removed++; } catch { }
            }
        }
        return removed;
    }

    public static void RemoveAll()
    {
        foreach (var id in AllIds())
        {
            try { System.IO.Directory.Delete(Directory(id), true); } catch { }
        }
        try { File.Delete(Path.Combine(Root, "latest")); } catch { }
    }

    // ---- markdown ----

    public static string RenderMarkdown(SnapshotMeta meta, string text, string? selectedText)
    {
        var s = new StringBuilder();
        s.Append("# App snapshot: ").Append(meta.AppName);
        if (!string.IsNullOrEmpty(meta.WindowTitle)) s.Append(" — ").Append(meta.WindowTitle);
        s.Append("\n\n");
        s.Append("- App: ").Append(meta.AppName);
        if (!string.IsNullOrEmpty(meta.BundleID)) s.Append(" (`").Append(meta.BundleID).Append("`)");
        s.Append('\n');
        if (!string.IsNullOrEmpty(meta.WindowTitle)) s.Append("- Window: ").Append(meta.WindowTitle).Append('\n');
        if (!string.IsNullOrEmpty(meta.Url)) s.Append("- URL: ").Append(meta.Url).Append('\n');
        if (!string.IsNullOrEmpty(meta.FolderPath)) s.Append("- Folder: `").Append(meta.FolderPath).Append("`\n");
        foreach (var d in meta.Details ?? new()) s.Append("- ").Append(d).Append('\n');
        s.Append("- Captured: ").Append(meta.CreatedAt.ToString("yyyy-MM-dd HH:mm:ss zzz", CultureInfo.InvariantCulture)).Append('\n');
        s.Append("- Screenshot: ").Append(meta.ScreenshotPath != null ? "`" + meta.ScreenshotPath + "`" : "none").Append('\n');
        s.Append("- Snapshot ID: `").Append(meta.Id).Append("`\n\n");
        if (meta.TextSource == "ocr")
            s.Append("> The window text below was recognized (OCR) from the screenshot, so it only covers what is visible on screen and may contain recognition errors.");
        else
            s.Append("> The window text below was read with Windows UI Automation. It includes content that is scrolled out of view, so it can be longer than what is visible in the screenshot.");
        if (meta.TextTruncated) s.Append(" The text was truncated.");
        s.Append('\n');

        if (meta.Warnings.Count > 0)
        {
            s.Append("\n## Warnings\n\n");
            foreach (var w in meta.Warnings) s.Append("- ").Append(w).Append('\n');
        }
        if (meta.SelectedPaths is { Count: > 0 })
        {
            s.Append("\n## Selected files\n\n");
            foreach (var p in meta.SelectedPaths)
            {
                s.Append("- `").Append(p).Append('`');
                var sum = FileSummary(p);
                if (sum != null) s.Append(" — ").Append(sum);
                s.Append('\n');
            }
        }
        if (meta.BrowserTabs is { Count: > 0 })
        {
            s.Append("\n## Tabs in this browser window\n\n");
            foreach (var t in meta.BrowserTabs) s.Append("- ").Append(t).Append('\n');
        }
        if (!string.IsNullOrEmpty(selectedText))
            s.Append("\n## Selected text\n\n").Append(selectedText).Append('\n');
        s.Append("\n## Window text\n\n");
        s.Append(string.IsNullOrEmpty(text) ? "(no text captured)\n" : text + "\n");
        return s.ToString();
    }

    public static string? FileSummary(string path)
    {
        try
        {
            if (System.IO.Directory.Exists(path))
            {
                int n = System.IO.Directory.EnumerateFileSystemEntries(path).Take(10001).Count();
                return n > 10000 ? "folder, more than 10000 items" : $"folder, {n} item{(n == 1 ? "" : "s")}";
            }
            var fi = new FileInfo(path);
            if (!fi.Exists) return null;
            return $"{FormatSize(fi.Length)}, modified {fi.LastWriteTime.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture)}";
        }
        catch { return null; }
    }

    static string FormatSize(long b)
    {
        string[] u = { "bytes", "KB", "MB", "GB", "TB" };
        double v = b;
        int i = 0;
        while (v >= 1024 && i < u.Length - 1) { v /= 1024; i++; }
        return i == 0 ? $"{b} bytes" : v.ToString(v >= 100 ? "0" : "0.#", CultureInfo.InvariantCulture) + " " + u[i];
    }
}
