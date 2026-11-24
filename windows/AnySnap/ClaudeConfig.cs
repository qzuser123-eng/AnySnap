using System.Text.Json;
using System.Text.Json.Nodes;

namespace AnySnap;

/// Adds AnySnap to Claude Desktop's MCP configuration (claude_desktop_config.json).
public static class ClaudeConfig
{
    public static string McpJson()
    {
        var obj = new JsonObject
        {
            ["mcpServers"] = new JsonObject
            {
                ["anysnap"] = new JsonObject
                {
                    ["command"] = Environment.ProcessPath,
                    ["args"] = new JsonArray("mcp"),
                },
            },
        };
        return obj.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    /// Config folders of the regular installer and of the Microsoft Store (MSIX) version.
    public static List<string> ConfigFiles()
    {
        var list = new List<string>();
        var roaming = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Claude");
        if (Directory.Exists(roaming)) list.Add(Path.Combine(roaming, "claude_desktop_config.json"));
        var packages = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Packages");
        try
        {
            foreach (var pkg in Directory.GetDirectories(packages, "Claude_*"))
            {
                var dir = Path.Combine(pkg, "LocalCache", "Roaming", "Claude");
                if (Directory.Exists(dir)) list.Add(Path.Combine(dir, "claude_desktop_config.json"));
            }
        }
        catch { }
        return list;
    }

    /// Returns the files that were updated. A backup is written next to each file first.
    public static List<string> Install()
    {
        var done = new List<string>();
        foreach (var file in ConfigFiles())
        {
            JsonObject root;
            if (File.Exists(file))
            {
                var text = File.ReadAllText(file);
                root = (string.IsNullOrWhiteSpace(text) ? new JsonObject() : JsonNode.Parse(text) as JsonObject)
                       ?? throw new InvalidDataException(file + " is not a JSON object");
                File.Copy(file, file + ".bak-anysnap-" + DateTime.Now.ToString("yyyyMMdd-HHmmss"), true);
            }
            else
            {
                root = new JsonObject();
            }
            if (root["mcpServers"] is not JsonObject servers)
            {
                servers = new JsonObject();
                root["mcpServers"] = servers;
            }
            servers["anysnap"] = new JsonObject
            {
                ["command"] = Environment.ProcessPath,
                ["args"] = new JsonArray("mcp"),
            };
            File.WriteAllText(file, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            done.Add(file);
        }
        return done;
    }
}
