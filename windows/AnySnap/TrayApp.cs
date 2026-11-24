using System.Diagnostics;
using System.Media;
using Microsoft.Win32;

namespace AnySnap;

/// The tray (notification area) app: hotkey → capture → paste / copy.
public sealed class TrayApp : ApplicationContext
{
    const string MutexName = "Local\\AnySnapTray";
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    readonly Settings _settings = Settings.Load();
    readonly NotifyIcon _icon;
    readonly Hotkeys _hotkeys;
    readonly System.Windows.Forms.Timer _pruneTimer;
    readonly SynchronizationContext _ui;
    readonly Icon _appIcon;
    IntPtr _lastForeground;
    IntPtr _winEventHook;
    readonly Native.WinEventDelegate _winEventProc;
    int _busy;

    public static bool IsRunning() => Mutex.TryOpenExisting(MutexName, out var m) && m != null;

    public static int Run()
    {
        using var mutex = new Mutex(true, MutexName, out bool created);
        if (!created)
        {
            MessageBox.Show(L.T("AnySnap 已经在运行了（在任务栏右下角的通知区域）。", "AnySnap is already running (see the notification area of the taskbar)."),
                "AnySnap", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 0;
        }
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new TrayApp());
        return 0;
    }

    TrayApp()
    {
        _ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        _appIcon = LoadIcon();
        _icon = new NotifyIcon
        {
            Icon = _appIcon,
            Text = "AnySnap",
            Visible = true,
            ContextMenuStrip = new ContextMenuStrip(),
        };
        _icon.ContextMenuStrip.Opening += (_, e) => { BuildMenu(); e.Cancel = false; };
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) CaptureFromMenu();
        };

        _hotkeys = new Hotkeys(OnHotkey);
        if (!_hotkeys.Start(_settings))
            Balloon(L.T("快捷键注册失败，可能被其他软件占用。请在托盘菜单里换一个。", "Could not register the hotkey (another app may use it). Pick another one in the tray menu."), ToolTipIcon.Warning);

        // Remember the last foreground window that isn't ours or the taskbar, for "capture" from the menu.
        _winEventProc = (_, _, hwnd, _, _, _, _) =>
        {
            if (WindowFinder.IsCandidate(hwnd, new HashSet<int>())) _lastForeground = hwnd;
        };
        _winEventHook = Native.SetWinEventHook(Native.EVENT_SYSTEM_FOREGROUND, Native.EVENT_SYSTEM_FOREGROUND, IntPtr.Zero,
            _winEventProc, 0, 0, Native.WINEVENT_OUTOFCONTEXT);

        SnapshotStore.PruneExpired();
        _pruneTimer = new System.Windows.Forms.Timer { Interval = 60 * 60 * 1000 };
        _pruneTimer.Tick += (_, _) => SnapshotStore.PruneExpired();
        _pruneTimer.Start();

        UpdateTooltip();
        if (!_settings.WelcomeShown)
        {
            Balloon(L.T($"AnySnap 已在这里运行。按 {_settings.HotkeyLabel} 截取前台窗口，右键图标打开菜单。",
                        $"AnySnap is running here. Press {_settings.HotkeyLabel} to capture the front window; right-click the icon for the menu."),
                ToolTipIcon.Info);
            _settings.WelcomeShown = true;
            _settings.Save();
        }
    }

    static Icon LoadIcon()
    {
        try
        {
            using var s = typeof(TrayApp).Assembly.GetManifestResourceStream("AnySnap.AnySnap.ico");
            if (s != null) return new Icon(s, SystemInformation.SmallIconSize);
        }
        catch { }
        return Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? SystemIcons.Application;
    }

    void UpdateTooltip()
    {
        var t = "AnySnap — " + _settings.HotkeyLabel;
        _icon.Text = t.Length > 63 ? t[..63] : t;
    }

    void Balloon(string text, ToolTipIcon icon = ToolTipIcon.None)
    {
        _icon.ShowBalloonTip(3000, "AnySnap", text, icon);
    }

    // ---- capture ----

    void OnHotkey()
    {
        // Called from the keyboard hook: capture the window that has the focus right now.
        var fg = Native.GetForegroundWindow();
        _ui.Post(_ => Capture(fg), null);
    }

    void CaptureFromMenu()
    {
        var target = _lastForeground;
        _ui.Post(_ => Capture(target), null);
    }

    void Capture(IntPtr preferred)
    {
        if (Interlocked.Exchange(ref _busy, 1) == 1) return;
        var o = new CaptureOptions { IncludeScreenshot = _settings.IncludeScreenshot, PreferredWindow = preferred };
        Task.Run(() =>
        {
            try
            {
                var meta = Snapshotter.Capture(o);
                var process = meta.BundleID != null ? Path.GetFileNameWithoutExtension(meta.BundleID) : "";
                _ui.Post(_ => Deliver(meta, process), null);
            }
            catch (Exception e)
            {
                var msg = e is CaptureException ? e.Message : e.ToString();
                _ui.Post(_ => Balloon(L.T("截取失败：", "Capture failed: ") + msg, ToolTipIcon.Error), null);
            }
            finally
            {
                Interlocked.Exchange(ref _busy, 0);
            }
        });
    }

    void Deliver(SnapshotMeta meta, string targetProcess)
    {
        if (_settings.PlaySound) PlayShutter();
        switch (_settings.Destination)
        {
            case Destination.Clipboard:
                Delivery.Copy(meta, _settings.ClipboardFormat, targetProcess);
                break;
            case Destination.Claude:
                // Claude reads the full text via MCP, so by default only the screenshot is pasted.
                var fmt = _settings.ClipboardFormat == ClipboardFormat.Auto
                    ? (meta.ScreenshotPath != null ? ClipboardFormat.Image : ClipboardFormat.Reference)
                    : _settings.ClipboardFormat;
                Delivery.Copy(meta, fmt, targetProcess);
                Task.Run(() =>
                {
                    if (!Delivery.PasteIntoClaude())
                        _ui.Post(_ => Balloon(L.T("没有找到正在运行的 Claude 桌面版，快照已复制到剪贴板。", "Claude Desktop is not running; the snapshot was copied to the clipboard."), ToolTipIcon.Info), null);
                });
                break;
            case Destination.SaveOnly:
                break;
        }
    }

    static void PlayShutter()
    {
        try
        {
            var wav = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Media", "Windows Notify System Generic.wav");
            if (File.Exists(wav)) new SoundPlayer(wav).Play();
            else SystemSounds.Asterisk.Play();
        }
        catch { }
    }

    // ---- menu ----

    static ToolStripMenuItem Item(string text, Action onClick, bool isChecked = false, bool enabled = true)
    {
        var i = new ToolStripMenuItem(text) { Checked = isChecked, Enabled = enabled };
        i.Click += (_, _) => onClick();
        return i;
    }

    void BuildMenu()
    {
        var menu = _icon.ContextMenuStrip!;
        menu.Items.Clear();

        menu.Items.Add(Item(L.T($"截取前台窗口（{_settings.HotkeyLabel}）", $"Capture front window ({_settings.HotkeyLabel})"), CaptureFromMenu));
        menu.Items.Add(new ToolStripSeparator());

        // Recent snapshots
        var recent = new ToolStripMenuItem(L.T("最近快照", "Recent snapshots"));
        var items = SnapshotStore.List(10);
        if (items.Count == 0) recent.DropDownItems.Add(Item(L.T("（还没有快照）", "(no snapshots yet)"), () => { }, enabled: false));
        foreach (var m in items)
        {
            var title = $"{m.CreatedAt:HH:mm:ss}  {m.AppName}";
            if (!string.IsNullOrEmpty(m.WindowTitle)) title += " — " + (m.WindowTitle.Length > 40 ? m.WindowTitle[..40] : m.WindowTitle);
            var snap = m;
            recent.DropDownItems.Add(Item(title.Replace("&", "&&"), () =>
                Delivery.Copy(snap, _settings.ClipboardFormat == ClipboardFormat.Auto ? ClipboardFormat.Files : _settings.ClipboardFormat, null)));
        }
        recent.DropDownItems.Add(new ToolStripSeparator());
        var keep = new ToolStripMenuItem(L.T("快照保留时间", "Keep snapshots for"));
        int current = SnapshotStore.RetentionDays;
        foreach (var (days, zh, en) in new[] { (1, "1 天", "1 day"), (3, "3 天（默认）", "3 days (default)"), (7, "7 天", "7 days"), (30, "30 天", "30 days"), (0, "永久保留", "Forever") })
        {
            int d = days;
            keep.DropDownItems.Add(Item(L.T(zh, en), () => { SnapshotStore.RetentionDays = d; SnapshotStore.PruneExpired(); }, current == days));
        }
        recent.DropDownItems.Add(keep);
        recent.DropDownItems.Add(Item(L.T("清空所有快照…", "Delete all snapshots…"), ConfirmClear));
        recent.DropDownItems.Add(Item(L.T("打开快照文件夹", "Open snapshot folder"), () =>
        {
            Directory.CreateDirectory(SnapshotStore.Root);
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{SnapshotStore.Root}\"") { UseShellExecute = true });
        }));
        menu.Items.Add(recent);

        // Destination
        var dest = new ToolStripMenuItem(L.T("快照目标位置", "After capture"));
        foreach (var (d, zh, en) in new[]
                 {
                     (Destination.Clipboard, "复制到剪贴板", "Copy to clipboard"),
                     (Destination.Claude, "发送到 Claude 桌面版（自动粘贴）", "Send to Claude Desktop (auto-paste)"),
                     (Destination.SaveOnly, "仅保存（供 MCP / CLI 读取）", "Save only (for MCP / CLI)"),
                 })
        {
            var dd = d;
            dest.DropDownItems.Add(Item(L.T(zh, en), () => { _settings.Destination = dd; _settings.Save(); }, _settings.Destination == d));
        }
        menu.Items.Add(dest);

        // Clipboard format
        var fmt = new ToolStripMenuItem(L.T("剪贴板格式", "Clipboard format"));
        foreach (var (f, zh, en) in new[]
                 {
                     (ClipboardFormat.Auto, "自动（发给 Claude 时只贴截图；终端用文字引用；其它用文件）", "Auto (screenshot for Claude, text reference for terminals, files otherwise)"),
                     (ClipboardFormat.Files, "截图 + 文字文件", "Screenshot + text file"),
                     (ClipboardFormat.Reference, "文字引用（路径，适合终端 agent）", "Text reference (paths, for terminal agents)"),
                     (ClipboardFormat.Image, "仅截图", "Screenshot only"),
                 })
        {
            var ff = f;
            fmt.DropDownItems.Add(Item(L.T(zh, en), () => { _settings.ClipboardFormat = ff; _settings.Save(); }, _settings.ClipboardFormat == f));
        }
        menu.Items.Add(fmt);

        // Hotkey
        var hk = new ToolStripMenuItem(L.T("快捷键", "Hotkey"));
        foreach (var (k, zh, en) in new[]
                 {
                     (HotkeyKind.LeftRightCtrl, "同时按下左右 Ctrl", "Left + right Ctrl together"),
                     (HotkeyKind.LeftRightAlt, "同时按下左右 Alt", "Left + right Alt together"),
                     (HotkeyKind.LeftRightShift, "同时按下左右 Shift", "Left + right Shift together"),
                 })
        {
            var kk = k;
            hk.DropDownItems.Add(Item(L.T(zh, en), () => SetHotkey(kk), _settings.Hotkey == k));
        }
        if (_settings.CustomHotkey != null)
            hk.DropDownItems.Add(Item(L.T("自定义：", "Custom: ") + _settings.CustomHotkey.Label, () => SetHotkey(HotkeyKind.Custom), _settings.Hotkey == HotkeyKind.Custom));
        hk.DropDownItems.Add(new ToolStripSeparator());
        hk.DropDownItems.Add(Item(L.T("录制自定义快捷键…", "Record custom hotkey…"), RecordHotkey));
        menu.Items.Add(hk);

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(Item(L.T("包含截图", "Include screenshot"), () => { _settings.IncludeScreenshot = !_settings.IncludeScreenshot; _settings.Save(); }, _settings.IncludeScreenshot));
        menu.Items.Add(Item(L.T("播放音效", "Play sound"), () => { _settings.PlaySound = !_settings.PlaySound; _settings.Save(); }, _settings.PlaySound));
        bool startup = IsStartupEnabled();
        menu.Items.Add(Item(L.T("开机时启动", "Start with Windows"), () => SetStartup(!startup), startup));

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(Item(L.T("连接到 Claude 桌面版（写入 MCP 配置）…", "Connect to Claude Desktop (add MCP config)…"), ConnectClaude));
        menu.Items.Add(Item(L.T("复制 MCP 配置（其他客户端）", "Copy MCP config (other clients)"), () =>
        {
            Clipboard.SetText(ClaudeConfig.McpJson());
            Balloon(L.T("MCP 配置已复制到剪贴板。", "MCP config copied to the clipboard."));
        }));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(Item(L.T("退出 AnySnap", "Quit AnySnap"), ExitThread));
    }

    void SetHotkey(HotkeyKind k)
    {
        _settings.Hotkey = k;
        _settings.Save();
        if (!_hotkeys.Start(_settings))
            MessageBox.Show(L.T("这个快捷键注册失败，可能被其他软件占用。", "Could not register this hotkey; another app may be using it."), "AnySnap");
        UpdateTooltip();
    }

    void RecordHotkey()
    {
        _hotkeys.Stop();
        using var dlg = new HotkeyRecorder();
        if (dlg.ShowDialog() == DialogResult.OK && dlg.Result != null)
        {
            _settings.CustomHotkey = dlg.Result;
            SetHotkey(HotkeyKind.Custom);
        }
        else
        {
            _hotkeys.Start(_settings);
        }
    }

    void ConfirmClear()
    {
        int n = SnapshotStore.AllIds().Count;
        if (MessageBox.Show(L.T($"删除全部 {n} 个快照？此操作无法撤销。", $"Delete all {n} snapshots? This cannot be undone."),
                "AnySnap", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) == DialogResult.OK)
            SnapshotStore.RemoveAll();
    }

    void ConnectClaude()
    {
        var files = ClaudeConfig.ConfigFiles();
        if (files.Count == 0)
        {
            MessageBox.Show(L.T("没有找到 Claude 桌面版的配置文件夹。请先安装并打开一次 Claude 桌面版；或者用「复制 MCP 配置」手动添加。",
                    "Claude Desktop's config folder was not found. Install and open Claude Desktop once, or use \"Copy MCP config\" to add it by hand."),
                "AnySnap", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        var exe = Environment.ProcessPath ?? "";
        var where = L.T($"将把 AnySnap（{exe}）加入 Claude 桌面版的 MCP 配置（会先备份原文件）。\n\n注意：之后不要再移动 AnySnap.exe，否则需要重新连接。\n\n继续吗？",
            $"AnySnap ({exe}) will be added to Claude Desktop's MCP config (the file is backed up first).\n\nDon't move AnySnap.exe afterwards, or connect again.\n\nContinue?");
        if (MessageBox.Show(where, "AnySnap", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
        try
        {
            var done = ClaudeConfig.Install();
            MessageBox.Show(L.T("完成。请完全退出 Claude 桌面版（托盘图标 → Quit）再重新打开。\n\n已更新：\n", "Done. Quit Claude Desktop completely (tray icon → Quit) and open it again.\n\nUpdated:\n")
                            + string.Join("\n", done), "AnySnap", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception e)
        {
            MessageBox.Show(L.T("写入失败：", "Failed: ") + e.Message, "AnySnap", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    static bool IsStartupEnabled()
    {
        using var k = Registry.CurrentUser.OpenSubKey(RunKey);
        return k?.GetValue("AnySnap") is string;
    }

    static void SetStartup(bool on)
    {
        using var k = Registry.CurrentUser.CreateSubKey(RunKey);
        if (on) k.SetValue("AnySnap", $"\"{Environment.ProcessPath}\"");
        else k.DeleteValue("AnySnap", false);
    }

    protected override void ExitThreadCore()
    {
        _hotkeys.Dispose();
        if (_winEventHook != IntPtr.Zero) Native.UnhookWinEvent(_winEventHook);
        _pruneTimer.Dispose();
        _icon.Visible = false;
        _icon.Dispose();
        base.ExitThreadCore();
    }
}
