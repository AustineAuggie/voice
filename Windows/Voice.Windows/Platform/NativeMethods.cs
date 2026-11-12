using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;

namespace Voice.Windows.Platform;

internal static class NativeMethods
{
    internal const int WmHotkey = 0x0312;
    internal const uint ModAlt = 0x0001, ModControl = 0x0002, ModNoRepeat = 0x4000;
    internal const ushort VkControl = 0x11, VkMenu = 0x12, VkShift = 0x10, VkLWin = 0x5B, VkRWin = 0x5C;

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UnregisterHotKey(nint hwnd, int id);
    [DllImport("user32.dll")] internal static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint hwnd, out uint processId);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsWindow(nint hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsWindowVisible(nint hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetWindowText(nint hwnd, StringBuilder value, int maxCount);
    [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] internal static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll", SetLastError = true)] internal static extern uint SendInput(uint count, [In] Input[] inputs, int size);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool EnumWindows(EnumWindowsProc callback, nint parameter);
    internal delegate bool EnumWindowsProc(nint hwnd, nint parameter);

    // INPUT must include the entire union (MOUSEINPUT is larger than KEYBDINPUT).
    [StructLayout(LayoutKind.Sequential)]
    internal struct Input { internal uint Type; internal InputUnion Data; }
    [StructLayout(LayoutKind.Explicit)]
    internal struct InputUnion
    {
        [FieldOffset(0)] internal KeyboardInput Keyboard;
        [FieldOffset(0)] internal MouseInput Mouse;
        [FieldOffset(0)] internal HardwareInput Hardware;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct KeyboardInput { internal ushort Key, Scan; internal uint Flags, Time; internal nuint ExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct MouseInput { internal int X, Y; internal uint MouseData, Flags, Time; internal nuint ExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HardwareInput { internal uint Message; internal ushort ParamLow, ParamHigh; }

    internal static Input Key(ushort code, bool up = false) => new()
    {
        Type = 1,
        Data = new InputUnion { Keyboard = new KeyboardInput { Key = code, Flags = up ? 0x0002u : 0 } }
    };
    internal static bool ModifiersHeld() => new[] { VkControl, VkMenu, VkShift, VkLWin, VkRWin }
        .Any(key => (GetAsyncKeyState(key) & 0x8000) != 0);
}
