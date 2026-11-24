using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Interop.UIAutomationClient;

namespace AnySnap;

public sealed class UiaResult
{
    public string Text = "";
    public bool Truncated;
    public string? Url;
    public List<string> Tabs = new();
    public string? SelectedText;
    public string? Error;
}

/// Reads a window's text with Windows UI Automation: the whole tree is fetched in one
/// cached request, so content scrolled out of view is included (browsers expose the
/// full page, editors the full document).
public static class UiaReader
{
    // property ids
    const int NameP = 30005, ControlTypeP = 30003, BoundsP = 30001, ClassNameP = 30012, AutomationIdP = 30011,
        IsOffscreenP = 30022, ValueP = 30045, IsTextPatternP = 30040, IsValuePatternP = 30043, ProcessIdP = 30002;
    const int TextPatternId = 10014;

    // control types
    const int Button = 50000, CheckBox = 50002, ComboBox = 50003, Edit = 50004, Hyperlink = 50005, Image = 50006,
        ListItem = 50007, MenuBar = 50010, MenuItem = 50011, RadioButton = 50013, ScrollBar = 50014, Tab = 50018,
        TabItem = 50019, Text = 50020, ToolBar = 50021, ToolTip = 50022, TreeItem = 50024, Group = 50026,
        Thumb = 50027, DataItem = 50029, Document = 50030, SplitButton = 50031, Window = 50032, Pane = 50033,
        Header = 50034, HeaderItem = 50035, TitleBar = 50037, Separator = 50038;

    static readonly HashSet<string> BrowserProcesses = new(StringComparer.OrdinalIgnoreCase)
        { "chrome", "msedge", "firefox", "brave", "opera", "vivaldi", "arc", "chromium", "thorium", "librewolf", "waterfox", "zen" };

    public static bool IsBrowser(string processName) => BrowserProcesses.Contains(processName);

    sealed class Node
    {
        public IUIAutomationElement El = null!;
        public int Type;
        public string Name = "";
        public string? Value;
        public bool HasText, HasValue;
        public List<Node> Kids = new();
    }

    public static UiaResult Read(TargetWindow target, int maxChars = 300_000)
    {
        var result = new UiaResult();
        try
        {
            var uia = (IUIAutomation)Activator.CreateInstance(
                Type.GetTypeFromCLSID(new Guid("e22ad333-b25f-460c-83d0-0581107395c9"))!)!; // CUIAutomation8
            if (uia is IUIAutomation2 u2)
            {
                u2.TransactionTimeout = 15000;
                u2.ConnectionTimeout = 5000;
            }

            var root = uia.ElementFromHandle(target.Hwnd);
            var tree = Fetch(uia, root);

            // Chromium/Electron apps build their accessibility tree only once a client asks:
            // the first pass can be nearly empty, so ask again after a moment.
            if (CountText(tree) < 200 && Native.ClassName(target.Hwnd).StartsWith("Chrome_WidgetWin", StringComparison.Ordinal))
            {
                Thread.Sleep(800);
                tree = Fetch(uia, root);
            }

            var sb = new StringBuilder();
            bool browser = IsBrowser(target.ProcessName);
            if (browser)
            {
                result.Url = FindUrl(tree);
                CollectTabs(tree, result.Tabs, insideDocument: false);
                var docs = new List<Node>();
                FindDocuments(tree, docs);
                foreach (var d in docs)
                {
                    var lines = new List<string>();
                    Walk(d, lines, maxChars);
                    Append(sb, lines);
                }
                if (sb.Length == 0)
                {
                    var lines = new List<string>();
                    Walk(tree, lines, maxChars);
                    Append(sb, lines);
                }
            }
            else
            {
                var lines = new List<string>();
                Walk(tree, lines, maxChars);
                Append(sb, lines);
            }

            var text = Normalize(sb.ToString());
            if (text.Length > maxChars)
            {
                text = text[..maxChars];
                result.Truncated = true;
            }
            result.Text = text;
            result.SelectedText = Selection(uia, target.Pid);
        }
        catch (Exception e)
        {
            result.Error = e.Message;
        }
        return result;
    }

    static Node Fetch(IUIAutomation uia, IUIAutomationElement root)
    {
        var cr = uia.CreateCacheRequest();
        foreach (var p in new[] { NameP, ControlTypeP, BoundsP, ClassNameP, AutomationIdP, IsOffscreenP, ValueP, IsTextPatternP, IsValuePatternP })
            cr.AddProperty(p);
        cr.TreeScope = (TreeScope)7; // element + all descendants
        cr.TreeFilter = uia.ControlViewCondition;
        var cached = root.BuildUpdatedCache(cr);
        return Build(cached, 0);
    }

    static Node Build(IUIAutomationElement el, int depth)
    {
        var n = new Node { El = el };
        try
        {
            n.Type = el.CachedControlType;
            n.Name = Clean(el.CachedName);
            n.HasText = Truthy(el.GetCachedPropertyValue(IsTextPatternP));
            n.HasValue = Truthy(el.GetCachedPropertyValue(IsValuePatternP));
            if (n.HasValue) n.Value = Clean(el.GetCachedPropertyValue(ValueP) as string);
        }
        catch (COMException) { }
        if (depth > 200) return n;
        try
        {
            var kids = el.GetCachedChildren();
            if (kids != null)
            {
                for (int i = 0; i < kids.Length; i++) n.Kids.Add(Build(kids.GetElement(i), depth + 1));
            }
        }
        catch (COMException) { }
        return n;
    }

    static bool Truthy(object? o) => o is bool b ? b : o is int i && i != 0;

    static string Clean(string? s)
    {
        if (string.IsNullOrEmpty(s)) return "";
        return s.Replace(' ', ' ').Replace("​", "").Trim();
    }

    static int CountText(Node n)
    {
        int c = n.Name.Length + (n.Value?.Length ?? 0);
        foreach (var k in n.Kids) c += CountText(k);
        return c;
    }

    // ---- text ----

    static void Walk(Node n, List<string> lines, int budget)
    {
        if (TotalLength(lines) > budget) return;
        switch (n.Type)
        {
            case ScrollBar or Thumb or TitleBar or MenuBar or Separator or ToolTip:
                return;
        }

        if (n.Type is Document or Edit)
        {
            var t = DocumentText(n, budget);
            if (!string.IsNullOrWhiteSpace(t))
            {
                lines.Add(t);
                return;
            }
        }

        if (n.Kids.Count == 0)
        {
            if (n.Type == Image && n.Name.Length == 0) return;
            var s = n.Name;
            if (n.Type is Edit or ComboBox && !string.IsNullOrEmpty(n.Value) && n.Value != n.Name)
                s = string.IsNullOrEmpty(n.Name) ? n.Value! : $"{n.Name}: {n.Value}";
            if (!string.IsNullOrEmpty(s)) lines.Add(s);
            return;
        }

        if (n.Type is ListItem or DataItem or TreeItem or Header)
        {
            // One line per row: "name  column  column ..."
            var parts = new List<string>();
            var kidLines = new List<string>();
            foreach (var k in n.Kids) Walk(k, kidLines, budget);
            var flat = kidLines.SelectMany(l => l.Split('\n')).Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
            if (n.Name.Length > 0 && !flat.Any(l => l.Contains(n.Name, StringComparison.Ordinal))) parts.Add(n.Name);
            parts.AddRange(flat.Distinct());
            if (parts.Count > 0) lines.Add(string.Join(n.Type == Header ? " | " : "  ", parts));
            return;
        }

        var sub = new List<string>();
        foreach (var k in n.Kids) Walk(k, sub, budget);
        if (n.Name.Length > 0 && n.Type is Text or Hyperlink or Button or CheckBox or RadioButton or MenuItem or TabItem or SplitButton or ComboBox
            && !sub.Any(l => l.Contains(n.Name, StringComparison.Ordinal)))
        {
            lines.Add(n.Name);
        }
        lines.AddRange(sub);
    }

    static string? DocumentText(Node n, int budget)
    {
        if (n.HasText)
        {
            try
            {
                if (n.El.GetCurrentPattern(TextPatternId) is IUIAutomationTextPattern tp)
                {
                    var t = tp.DocumentRange.GetText(budget + 1);
                    if (!string.IsNullOrWhiteSpace(t)) return t;
                }
            }
            catch (COMException) { }
            catch (InvalidCastException) { }
        }
        if (!string.IsNullOrWhiteSpace(n.Value) && n.Type == Edit) return n.Value;
        return null;
    }

    static int TotalLength(List<string> lines)
    {
        int c = 0;
        foreach (var l in lines) c += l.Length + 1;
        return c;
    }

    static void Append(StringBuilder sb, List<string> lines)
    {
        string? prev = null;
        foreach (var l in lines)
        {
            if (l == prev) continue;
            if (sb.Length > 0) sb.Append('\n');
            sb.Append(l);
            prev = l;
        }
    }

    static string Normalize(string s)
    {
        s = s.Replace("\r\n", "\n").Replace('\r', '\n');
        s = Regex.Replace(s, "\n{3,}", "\n\n");
        return s.Trim();
    }

    // ---- browsers ----

    static readonly Regex UrlLike = new(@"^(https?://|file:///|edge://|chrome://|about:|view-source:|[a-z0-9-]+(\.[a-z0-9-]+)+(:\d+)?(/|$)|localhost(:\d+)?(/|$)|[a-z]:[/\\])",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    static string? FindUrl(Node n)
    {
        if (n.Type == Document) return null;
        if (n.Type == Edit && !string.IsNullOrEmpty(n.Value) && UrlLike.IsMatch(n.Value) && !n.Value.Contains(' '))
            return n.Value;
        foreach (var k in n.Kids)
        {
            var u = FindUrl(k);
            if (u != null) return u;
        }
        return null;
    }

    static void CollectTabs(Node n, List<string> tabs, bool insideDocument)
    {
        if (n.Type == Document) return;
        if (n.Type == TabItem && n.Name.Length > 0) tabs.Add(n.Name);
        foreach (var k in n.Kids) CollectTabs(k, tabs, insideDocument);
    }

    static void FindDocuments(Node n, List<Node> docs)
    {
        if (n.Type == Document)
        {
            docs.Add(n);
            return;
        }
        foreach (var k in n.Kids) FindDocuments(k, docs);
    }

    // ---- selection ----

    static string? Selection(IUIAutomation uia, int pid)
    {
        try
        {
            var focused = uia.GetFocusedElement();
            if (focused == null || focused.CurrentProcessId != pid) return null;
            if (focused.GetCurrentPattern(TextPatternId) is not IUIAutomationTextPattern tp) return null;
            var ranges = tp.GetSelection();
            if (ranges == null) return null;
            var sb = new StringBuilder();
            for (int i = 0; i < ranges.Length; i++)
            {
                var t = ranges.GetElement(i).GetText(20000);
                if (!string.IsNullOrEmpty(t)) sb.Append(t);
            }
            var s = sb.ToString().Trim();
            return s.Length == 0 ? null : s;
        }
        catch { return null; }
    }
}
