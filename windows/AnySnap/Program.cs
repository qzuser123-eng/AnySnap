using System.Text;

namespace AnySnap;

public static class Program
{
    public const string Version = "0.1.0";

    const string Usage = """
        AnySnap {0} — app snapshots for AI agents (Windows)

        USAGE
          AnySnap.exe                         Start the tray app (hotkey: left Ctrl + right Ctrl)
          AnySnap.exe mcp                     Run as an MCP server over stdio
          AnySnap.exe capture [--app NAME] [--no-screenshot] [--json|--context]
                                              Capture the frontmost window (the calling terminal is skipped)
          AnySnap.exe latest [--json|--context]
          AnySnap.exe list [N]
          AnySnap.exe show ID [--json|--context]
          AnySnap.exe doctor

        Tip: in PowerShell, pipe CLI commands to Out-Host (e.g. `.\AnySnap.exe latest | Out-Host`)
        so the prompt waits for the output. Snapshots are stored in {1}
        """;

    [STAThread]
    public static int Main(string[] args)
    {
        Native.SetProcessDpiAwarenessContext(Native.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        var cmd = args.Length > 0 ? args[0].ToLowerInvariant() : "";

        if (cmd == "")
        {
            return TrayApp.Run();
        }

        if (cmd == "mcp")
        {
            var server = new McpServer(Console.OpenStandardOutput());
            server.Run(Console.OpenStandardInput());
            return 0;
        }

        return Cli(cmd, args);
    }

    /// UI Automation and the capture code run on an MTA thread.
    public static T RunMta<T>(Func<T> f)
    {
        T? result = default;
        Exception? error = null;
        var t = new Thread(() =>
        {
            try { result = f(); }
            catch (Exception e) { error = e; }
        });
        t.SetApartmentState(ApartmentState.MTA);
        t.IsBackground = true;
        t.Start();
        t.Join();
        if (error != null) throw error;
        return result!;
    }

    // ---- CLI ----

    static TextWriter Out = TextWriter.Null;

    static void SetupConsole()
    {
        // This is a GUI (WinExe) program: use the redirected handles if there are any,
        // otherwise attach to the console of the terminal that started us.
        var h = Native.GetStdHandle(Native.STD_OUTPUT_HANDLE);
        bool redirected = h != IntPtr.Zero && h != new IntPtr(-1) && Native.GetFileType(h) != 0;
        if (!redirected) Native.AttachConsole(Native.ATTACH_PARENT_PROCESS);
        Out = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true };
        if (!redirected) Out.WriteLine();
    }

    static int Cli(string cmd, string[] args)
    {
        SetupConsole();
        bool Flag(string f) => args.Contains(f, StringComparer.OrdinalIgnoreCase);
        string? Value(string f)
        {
            int i = Array.FindIndex(args, a => a.Equals(f, StringComparison.OrdinalIgnoreCase));
            return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        }
        void Output(SnapshotMeta m)
        {
            if (Flag("--json")) Out.WriteLine(SnapshotStore.Json(m));
            else if (Flag("--context")) Out.WriteLine(SnapshotStore.Context(m));
            else Out.WriteLine(Delivery.ReferenceText(m));
        }

        switch (cmd)
        {
            case "capture":
                try
                {
                    var o = new CaptureOptions
                    {
                        IncludeScreenshot = !Flag("--no-screenshot"),
                        AppName = Value("--app"),
                        ExcludePids = Flag("--include-host") ? new() : WindowFinder.AncestorPids(),
                    };
                    Output(RunMta(() => Snapshotter.Capture(o)));
                    return 0;
                }
                catch (Exception e)
                {
                    Out.WriteLine("capture failed: " + e.Message);
                    return 1;
                }
            case "latest":
            {
                var m = SnapshotStore.Latest();
                if (m == null) { Out.WriteLine("no snapshots yet"); return 1; }
                Output(m);
                return 0;
            }
            case "list":
            {
                int n = args.Length > 1 && int.TryParse(args[1], out var k) ? k : 20;
                foreach (var m in SnapshotStore.List(n))
                    Out.WriteLine($"{m.Id}\t{m.CreatedAt:yyyy-MM-ddTHH:mm:sszzz}\t{m.AppName}\t{m.WindowTitle}");
                return 0;
            }
            case "show":
            {
                var m = args.Length > 1 ? SnapshotStore.Load(args[1]) : null;
                if (m == null) { Out.WriteLine("snapshot not found"); return 1; }
                Output(m);
                return 0;
            }
            case "doctor":
                Out.WriteLine($"AnySnap {Version}");
                Out.WriteLine($"Executable:       {Environment.ProcessPath}");
                Out.WriteLine($"Snapshot folder:  {SnapshotStore.Root}");
                Out.WriteLine($"Keep snapshots:   {(SnapshotStore.RetentionDays == 0 ? "forever" : SnapshotStore.RetentionDays + " days")}");
                Out.WriteLine($"Tray app running: {(TrayApp.IsRunning() ? "yes" : "no")}");
                Out.WriteLine($"Claude Desktop:   {(Delivery.FindClaudeWindow() != IntPtr.Zero ? "running" : "not running")}");
                Out.WriteLine("Windows needs no extra permissions for AnySnap (no Accessibility / Screen Recording settings).");
                return 0;
            default:
                Out.WriteLine(string.Format(Usage, Version, SnapshotStore.Root));
                return cmd is "help" or "--help" or "-h" or "/?" ? 0 : 1;
        }
    }
}
