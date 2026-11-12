using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Interop;

namespace Voice.Windows.Platform;

/// <summary>Registers only Voice's shortcuts; it does not install a keyboard hook.</summary>
public sealed class GlobalHotkey : IDisposable
{
    private const int ToggleId = 0x5601, CancelId = 0x5602;
    private HwndSource? source;
    private nint handle;
    private bool cancelEnabled;
    public event Action? ToggleRequested;
    public event Action? CancelRequested;

    public void Register(Window window)
    {
        window.Dispatcher.VerifyAccess();
        if (source is not null) return;
        handle = new WindowInteropHelper(window).EnsureHandle();
        source = HwndSource.FromHwnd(handle) ?? throw new InvalidOperationException("The Voice window is not ready.");
        source.AddHook(WindowMessage);
        if (!NativeMethods.RegisterHotKey(handle, ToggleId,
            NativeMethods.ModControl | NativeMethods.ModAlt | NativeMethods.ModNoRepeat, 0x20))
        {
            source.RemoveHook(WindowMessage); source = null;
            throw new Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error(),
                "Ctrl+Alt+Space is already used by another app. You can still use Voice's Start button.");
        }
    }

    public void SetCancellationEnabled(bool enabled)
    {
        if (source is null || cancelEnabled == enabled) return;
        if (enabled)
            cancelEnabled = NativeMethods.RegisterHotKey(handle, CancelId, NativeMethods.ModNoRepeat, 0x1B);
        else
        {
            NativeMethods.UnregisterHotKey(handle, CancelId);
            cancelEnabled = false;
        }
    }

    private nint WindowMessage(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message != NativeMethods.WmHotkey) return 0;
        if ((int)wParam == ToggleId) { handled = true; ToggleRequested?.Invoke(); }
        else if ((int)wParam == CancelId && cancelEnabled) { handled = true; CancelRequested?.Invoke(); }
        return 0;
    }

    public void Dispose()
    {
        if (source is null) return;
        SetCancellationEnabled(false);
        NativeMethods.UnregisterHotKey(handle, ToggleId);
        source.RemoveHook(WindowMessage); source = null; handle = 0;
    }
}
