using System.Runtime.InteropServices;

namespace AnySnap;

/// Global hotkeys. "Both left and right Ctrl/Alt/Shift" uses a low-level keyboard hook;
/// a custom key combination uses RegisterHotKey.
public sealed class Hotkeys : NativeWindow, IDisposable
{
    readonly Action _fire;
    IntPtr _hook;
    Native.LowLevelKeyboardProc? _proc;
    int _left, _right;
    bool _leftDown, _rightDown, _other, _fired;
    bool _registered;
    const int HotkeyId = 0xA51;

    public Hotkeys(Action fire)
    {
        _fire = fire;
        CreateHandle(new CreateParams());
    }

    public bool Start(Settings s)
    {
        Stop();
        switch (s.Hotkey)
        {
            case HotkeyKind.LeftRightCtrl: return Hook(Native.VK_LCONTROL, Native.VK_RCONTROL);
            case HotkeyKind.LeftRightAlt: return Hook(Native.VK_LMENU, Native.VK_RMENU);
            case HotkeyKind.LeftRightShift: return Hook(Native.VK_LSHIFT, Native.VK_RSHIFT);
            case HotkeyKind.Custom when s.CustomHotkey != null:
                _registered = Native.RegisterHotKey(Handle, HotkeyId, s.CustomHotkey.Modifiers | Native.MOD_NOREPEAT, s.CustomHotkey.Key);
                return _registered;
            default:
                return Hook(Native.VK_LCONTROL, Native.VK_RCONTROL);
        }
    }

    bool Hook(int left, int right)
    {
        _left = left;
        _right = right;
        _leftDown = _rightDown = _other = _fired = false;
        _proc = HookProc;
        _hook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, _proc, Native.GetModuleHandle(null), 0);
        return _hook != IntPtr.Zero;
    }

    IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var k = Marshal.PtrToStructure<Native.KBDLLHOOKSTRUCT>(lParam);
            int msg = wParam.ToInt32();
            bool down = msg is Native.WM_KEYDOWN or Native.WM_SYSKEYDOWN;
            bool up = msg is Native.WM_KEYUP or Native.WM_SYSKEYUP;
            int vk = (int)k.vkCode;
            if (down)
            {
                if (vk == _left) _leftDown = true;
                else if (vk == _right) _rightDown = true;
                else if (_leftDown || _rightDown) _other = true; // e.g. Ctrl+C: not our hotkey
                if (_leftDown && _rightDown && !_fired && !_other)
                {
                    _fired = true;
                    _fire();
                }
            }
            else if (up)
            {
                if (vk == _left) _leftDown = false;
                else if (vk == _right) _rightDown = false;
                if (!_leftDown && !_rightDown)
                {
                    _fired = false;
                    _other = false;
                }
            }
        }
        return Native.CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == Native.WM_HOTKEY && m.WParam.ToInt32() == HotkeyId) _fire();
        base.WndProc(ref m);
    }

    public void Stop()
    {
        if (_hook != IntPtr.Zero)
        {
            Native.UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }
        if (_registered)
        {
            Native.UnregisterHotKey(Handle, HotkeyId);
            _registered = false;
        }
    }

    public void Dispose()
    {
        Stop();
        DestroyHandle();
    }
}
