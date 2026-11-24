using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AnySnap;

public enum Destination { Clipboard, Claude, SaveOnly }
public enum HotkeyKind { LeftRightCtrl, LeftRightAlt, LeftRightShift, Custom }

public sealed class CustomHotkey
{
    public uint Modifiers { get; set; }
    public uint Key { get; set; }
    public string Label { get; set; } = "";
}

/// Settings stored in %LOCALAPPDATA%\AnySnap\settings.json
public sealed class Settings
{
    [JsonConverter(typeof(JsonStringEnumConverter))] public HotkeyKind Hotkey { get; set; } = HotkeyKind.LeftRightCtrl;
    public CustomHotkey? CustomHotkey { get; set; }
    [JsonConverter(typeof(JsonStringEnumConverter))] public Destination Destination { get; set; } = Destination.Claude;
    [JsonConverter(typeof(JsonStringEnumConverter))] public ClipboardFormat ClipboardFormat { get; set; } = ClipboardFormat.Auto;
    public bool IncludeScreenshot { get; set; } = true;
    public bool PlaySound { get; set; } = true;
    public bool WelcomeShown { get; set; }

    static string FilePath => Path.Combine(SnapshotStore.AppDataDir, "settings.json");

    public static Settings Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings();
        }
        catch { }
        return new Settings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(SnapshotStore.AppDataDir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }

    public string HotkeyLabel => Hotkey switch
    {
        HotkeyKind.LeftRightCtrl => L.T("左 Ctrl + 右 Ctrl", "Left Ctrl + Right Ctrl"),
        HotkeyKind.LeftRightAlt => L.T("左 Alt + 右 Alt", "Left Alt + Right Alt"),
        HotkeyKind.LeftRightShift => L.T("左 Shift + 右 Shift", "Left Shift + Right Shift"),
        _ => CustomHotkey?.Label ?? "?",
    };
}

/// Chinese UI when Windows is set to Chinese, English otherwise.
public static class L
{
    public static readonly bool Zh = (Environment.GetEnvironmentVariable("ANYSNAP_LANG") ?? CultureInfo.CurrentUICulture.Name)
        .StartsWith("zh", StringComparison.OrdinalIgnoreCase);
    public static string T(string zh, string en) => Zh ? zh : en;
}
