using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AnySnap;

/// Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0), same tools as the macOS version.
public sealed class McpServer
{
    const int DefaultMaxChars = 40_000;
    readonly Stream _out;

    const string Instructions =
        "AnySnap lets the user share a Windows app window with you. When the user presses the AnySnap hotkey " +
        "(left Ctrl + right Ctrl by default), only a screenshot of the window is pasted into the chat, while the " +
        "full window text (read with UI Automation, including content scrolled off-screen) is saved " +
        "as a snapshot. So whenever a user message contains a screenshot of an app window, or the user says " +
        "\"look at this\", \"this window\", \"what I just captured\" and similar, call get_latest_snapshot with " +
        "include_screenshot=false before answering, and use its text together with the image. If several " +
        "screenshots were sent, call list_snapshots and get_snapshot for the matching ones (compare app, " +
        "window title and time). Each result starts with how long ago it was taken: if the app/window " +
        "does not match the image, or it is clearly older than the screenshot the user just sent (for " +
        "example a manual screenshot), ignore it and rely on the image alone. Do not mention this lookup " +
        "to the user unless it fails or does not match. " +
        "Call capture_window to grab their frontmost window yourself when asked.";

    public McpServer(Stream output) => _out = output;

    static JsonObject Schema(JsonObject props, params string[] required)
    {
        var s = new JsonObject { ["type"] = "object", ["properties"] = props };
        if (required.Length > 0) s["required"] = new JsonArray(required.Select(r => (JsonNode)r).ToArray());
        return s;
    }

    static JsonObject Prop(string type, string description) => new() { ["type"] = type, ["description"] = description };

    static JsonArray Tools()
    {
        JsonObject Shot() => Prop("boolean", "Attach the window screenshot (default true). Set false for text-only models.");
        JsonObject Max() => Prop("integer", $"Max characters of window text to return (default {DefaultMaxChars}).");
        JsonObject Tool(string name, string description, JsonObject schema) =>
            new() { ["name"] = name, ["description"] = description, ["inputSchema"] = schema };

        return new JsonArray(
            Tool("get_latest_snapshot",
                "Get the most recent app snapshot the user captured with the AnySnap hotkey. Call this whenever the user sends a screenshot of an app window: the chat only shows the image, this returns the window's full text (including text scrolled off-screen), app name, window title and URL. Use include_screenshot=false when the image is already in the chat.",
                Schema(new JsonObject { ["include_screenshot"] = Shot(), ["max_chars"] = Max() })),
            Tool("capture_window",
                "Capture the user's frontmost app window right now (the AI client's own window is skipped). Returns screenshot + UI Automation text including off-screen text. Optionally target a specific app.",
                Schema(new JsonObject
                {
                    ["app"] = Prop("string", "Optional app or process name, e.g. \"Chrome\", \"notepad\" or \"explorer\"."),
                    ["include_screenshot"] = Shot(),
                    ["max_chars"] = Max(),
                })),
            Tool("list_snapshots",
                "List recent snapshots (id, time, app, window title).",
                Schema(new JsonObject { ["limit"] = Prop("integer", "Default 10.") })),
            Tool("get_snapshot",
                "Get a specific snapshot by id (from list_snapshots).",
                Schema(new JsonObject
                {
                    ["id"] = Prop("string", "Snapshot id from list_snapshots."),
                    ["include_screenshot"] = Shot(),
                    ["max_chars"] = Max(),
                }, "id")));
    }

    public void Run(Stream input)
    {
        using var reader = new StreamReader(input, new UTF8Encoding(false));
        string? line;
        while ((line = reader.ReadLine()) != null)
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            JsonObject? msg;
            try { msg = JsonNode.Parse(line) as JsonObject; }
            catch (JsonException) { msg = null; }
            if (msg == null)
            {
                Send(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = null, ["error"] = new JsonObject { ["code"] = -32700, ["message"] = "Parse error" } });
                continue;
            }
            try { Handle(msg); }
            catch (Exception e)
            {
                if (msg["id"] is JsonNode id) Fail(id.DeepClone(), -32603, "Internal error: " + e.Message);
            }
        }
    }

    void Send(JsonObject obj)
    {
        var bytes = Encoding.UTF8.GetBytes(obj.ToJsonString(new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }) + "\n");
        lock (_out)
        {
            _out.Write(bytes);
            _out.Flush();
        }
    }

    void Reply(JsonNode id, JsonObject result) => Send(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["result"] = result });

    void Fail(JsonNode id, int code, string message) =>
        Send(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["error"] = new JsonObject { ["code"] = code, ["message"] = message } });

    void Handle(JsonObject msg)
    {
        var method = msg["method"]?.GetValue<string>() ?? "";
        if (msg["id"] is not JsonNode idNode) return; // notification
        var id = idNode.DeepClone();
        var p = msg["params"] as JsonObject ?? new JsonObject();

        switch (method)
        {
            case "initialize":
                var version = p["protocolVersion"]?.GetValue<string>() ?? "2025-06-18";
                Reply(id, new JsonObject
                {
                    ["protocolVersion"] = version,
                    ["capabilities"] = new JsonObject { ["tools"] = new JsonObject() },
                    ["serverInfo"] = new JsonObject { ["name"] = "anysnap", ["version"] = Program.Version },
                    ["instructions"] = Instructions,
                });
                break;
            case "ping":
                Reply(id, new JsonObject());
                break;
            case "tools/list":
                Reply(id, new JsonObject { ["tools"] = Tools() });
                break;
            case "tools/call":
                CallTool(id, p);
                break;
            default:
                Fail(id, -32601, "Method not found: " + method);
                break;
        }
    }

    static bool Bool(JsonObject a, string k, bool def)
    {
        try { return a[k]?.GetValue<bool>() ?? def; } catch { return def; }
    }

    static int Int(JsonObject a, string k, int def)
    {
        try { return a[k] is JsonValue v ? (v.TryGetValue<int>(out var i) ? i : (int)v.GetValue<double>()) : def; }
        catch { return def; }
    }

    static string? Str(JsonObject a, string k)
    {
        try { return a[k]?.GetValue<string>(); } catch { return null; }
    }

    void CallTool(JsonNode id, JsonObject p)
    {
        var name = Str(p, "name") ?? "";
        var args = p["arguments"] as JsonObject ?? new JsonObject();
        bool withShot = Bool(args, "include_screenshot", true);
        int maxChars = Int(args, "max_chars", DefaultMaxChars);

        switch (name)
        {
            case "get_latest_snapshot":
            {
                var m = SnapshotStore.Latest();
                if (m == null)
                {
                    ToolText(id, "No snapshots yet. Ask the user to focus the window they want to share and press the AnySnap hotkey (left Ctrl + right Ctrl by default), or call capture_window.", true);
                    return;
                }
                ToolSnapshot(id, m, withShot, maxChars);
                return;
            }
            case "get_snapshot":
            {
                var sid = Str(args, "id");
                var m = sid != null ? SnapshotStore.Load(sid) : null;
                if (m == null) { ToolText(id, "Snapshot not found.", true); return; }
                ToolSnapshot(id, m, withShot, maxChars);
                return;
            }
            case "list_snapshots":
            {
                int limit = Int(args, "limit", 10);
                var lines = SnapshotStore.List(limit).Select(m =>
                    $"- {m.Id} | {m.CreatedAt:yyyy-MM-ddTHH:mm:sszzz} | {m.AppName}{(string.IsNullOrEmpty(m.WindowTitle) ? "" : " — " + m.WindowTitle)}");
                var text = string.Join("\n", lines);
                ToolText(id, text.Length == 0 ? "No snapshots yet." : text, false);
                return;
            }
            case "capture_window":
            {
                var o = new CaptureOptions { IncludeScreenshot = withShot, AppName = Str(args, "app") };
                if (string.IsNullOrWhiteSpace(o.AppName)) o.AppName = null;
                o.ExcludePids = WindowFinder.AncestorPids();
                try
                {
                    var m = Program.RunMta(() => Snapshotter.Capture(o));
                    ToolSnapshot(id, m, withShot, maxChars);
                }
                catch (Exception e)
                {
                    ToolText(id, "Capture failed: " + (e is CaptureException ? e.Message : e.ToString()), true);
                }
                return;
            }
            default:
                Fail(id, -32602, "Unknown tool: " + name);
                return;
        }
    }

    void ToolText(JsonNode id, string text, bool isError)
    {
        Reply(id, new JsonObject
        {
            ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = text }),
            ["isError"] = isError,
        });
    }

    void ToolSnapshot(JsonNode id, SnapshotMeta m, bool withShot, int maxChars)
    {
        int age = (int)(DateTimeOffset.Now - m.CreatedAt).TotalSeconds;
        string ageText = age < 120 ? $"{age} seconds" : age < 7200 ? $"{age / 60} minutes" : $"{age / 3600} hours";
        var text = $"[Snapshot taken {ageText} ago — app: {m.AppName}{(string.IsNullOrEmpty(m.WindowTitle) ? "" : ", window: " + m.WindowTitle)}]\n\n"
                   + SnapshotStore.Context(m);
        if (maxChars > 0 && text.Length > maxChars)
            text = text[..maxChars] + $"\n\n[... truncated to {maxChars} characters; full text: {m.ContextPath}]";
        var content = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = text });
        if (withShot && m.ScreenshotPath != null)
        {
            var jpg = ScreenCapture.JpegFromFile(m.ScreenshotPath);
            if (jpg != null)
                content.Add(new JsonObject { ["type"] = "image", ["data"] = Convert.ToBase64String(jpg), ["mimeType"] = "image/jpeg" });
        }
        Reply(id, new JsonObject { ["content"] = content, ["isError"] = false });
    }
}
