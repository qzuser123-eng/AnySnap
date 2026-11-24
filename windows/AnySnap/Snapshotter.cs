using System.Drawing.Imaging;

namespace AnySnap;

public sealed class CaptureOptions
{
    public string? AppName;
    public bool IncludeScreenshot = true;
    public HashSet<int> ExcludePids = new();
    public IntPtr PreferredWindow;
}

public sealed class CaptureException(string message) : Exception(message);

public static class Snapshotter
{
    /// Password managers are never captured.
    static readonly HashSet<string> SensitiveProcesses = new(StringComparer.OrdinalIgnoreCase)
    {
        "1Password", "KeePass", "KeePassXC", "Bitwarden", "Dashlane", "LastPass", "Enpass", "NordPass", "RoboForm",
        "Keeper", "keeperpasswordmanager", "ProtonPass", "CredentialUIBroker", "consent",
    };

    public static SnapshotMeta Capture(CaptureOptions o)
    {
        var target = WindowFinder.Find(o.AppName, o.ExcludePids, o.PreferredWindow)
            ?? throw new CaptureException(o.AppName != null ? $"No window found for \"{o.AppName}\"." : "No window to capture.");
        if (SensitiveProcesses.Contains(target.ProcessName))
            throw new CaptureException($"{target.AppName} is a password manager; AnySnap does not capture it.");

        var meta = new SnapshotMeta
        {
            Id = SnapshotStore.NewId(),
            CreatedAt = DateTimeOffset.Now,
            AppName = target.AppName,
            BundleID = target.ExePath,
            Pid = target.Pid,
            WindowTitle = string.IsNullOrEmpty(target.Title) ? null : target.Title,
        };
        var dir = SnapshotStore.CreateDirectory(meta.Id);
        meta.ContextPath = Path.Combine(dir, "context.md");
        var f = Native.FrameBounds(target.Hwnd);
        meta.Frame = new double[] { f.Left, f.Top, f.Width, f.Height };

        // Screenshot first: it's what the user saw at the moment of the hotkey.
        System.Drawing.Bitmap? shot = null;
        if (o.IncludeScreenshot)
        {
            shot = ScreenCapture.Capture(target.Hwnd, out var warn);
            if (warn != null) meta.Warnings.Add(warn);
            if (shot != null)
            {
                var p = Path.Combine(dir, "screenshot.png");
                shot.Save(p, ImageFormat.Png);
                meta.ScreenshotPath = p;
            }
        }

        try
        {
            var uia = UiaReader.Read(target);
            if (uia.Error != null) meta.Warnings.Add("UI Automation: " + uia.Error);
            string text = uia.Text;
            meta.TextSource = "accessibility";
            meta.Url = uia.Url;
            if (uia.Tabs.Count > 1) meta.BrowserTabs = uia.Tabs;
            meta.TextTruncated = uia.Truncated;

            if (target.ProcessName.Equals("explorer", StringComparison.OrdinalIgnoreCase))
            {
                var (folder, selected) = ExplorerInfo.Read(target.Hwnd, target.Title);
                meta.FolderPath = folder;
                if (selected.Count > 0) meta.SelectedPaths = selected;
            }

            // Little or no text from UI Automation (games, canvas apps, some custom UIs): OCR the screenshot.
            if (text.Length < 40 && shot != null)
            {
                var ocr = Ocr.Recognize(shot);
                if (!string.IsNullOrWhiteSpace(ocr) && ocr.Length > text.Length)
                {
                    text = ocr;
                    meta.TextSource = "ocr";
                }
            }

            meta.TextCharacters = text.Length;
            var md = SnapshotStore.RenderMarkdown(meta, text, uia.SelectedText);
            SnapshotStore.Save(meta, md);
            return meta;
        }
        finally
        {
            shot?.Dispose();
        }
    }
}
