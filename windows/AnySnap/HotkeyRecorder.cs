namespace AnySnap;

/// Small dialog that records a custom key combination (e.g. Ctrl+Shift+S).
public sealed class HotkeyRecorder : Form
{
    readonly Label _shown;
    readonly Button _ok;
    public CustomHotkey? Result { get; private set; }

    public HotkeyRecorder()
    {
        Text = L.T("录制快捷键", "Record hotkey");
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ShowInTaskbar = true;
        TopMost = true;
        KeyPreview = true;
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(380, 150);

        var hint = new Label
        {
            Text = L.T("按下新的快捷键组合（需要包含 Ctrl、Alt 或 Shift）", "Press the new key combination (must include Ctrl, Alt or Shift)"),
            AutoSize = false, Left = 16, Top = 14, Width = 348, Height = 36,
        };
        _shown = new Label
        {
            Text = "…", AutoSize = false, Left = 16, Top = 54, Width = 348, Height = 30,
            Font = new Font(Font.FontFamily, 13, FontStyle.Bold), TextAlign = ContentAlignment.MiddleCenter,
        };
        _ok = new Button { Text = L.T("确定", "OK"), Left = 196, Top = 104, Width = 80, Enabled = false, DialogResult = DialogResult.OK };
        var cancel = new Button { Text = L.T("取消", "Cancel"), Left = 284, Top = 104, Width = 80, DialogResult = DialogResult.Cancel };
        Controls.AddRange(new Control[] { hint, _shown, _ok, cancel });
        CancelButton = cancel;
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        var key = keyData & Keys.KeyCode;
        var mods = keyData & Keys.Modifiers;
        if (key is Keys.ControlKey or Keys.ShiftKey or Keys.Menu or Keys.LWin or Keys.RWin or Keys.None)
            return true;
        if (key == Keys.Escape && mods == Keys.None) return base.ProcessCmdKey(ref msg, keyData);
        if (mods == Keys.None) return true;

        uint m = 0;
        var parts = new List<string>();
        if ((mods & Keys.Control) != 0) { m |= Native.MOD_CONTROL; parts.Add("Ctrl"); }
        if ((mods & Keys.Alt) != 0) { m |= Native.MOD_ALT; parts.Add("Alt"); }
        if ((mods & Keys.Shift) != 0) { m |= Native.MOD_SHIFT; parts.Add("Shift"); }
        parts.Add(new KeysConverter().ConvertToString(key) ?? key.ToString());
        Result = new CustomHotkey { Modifiers = m, Key = (uint)key, Label = string.Join(" + ", parts) };
        _shown.Text = Result.Label;
        _ok.Enabled = true;
        return true;
    }
}
