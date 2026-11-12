using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;

namespace Voice.Windows;

/// <summary>A small status surface that never takes the text destination's keyboard focus.</summary>
public partial class PillWindow : Window
{
    private const int GwlExStyle = -20;
    private const long WsExNoActivate = 0x08000000;
    private const long WsExToolWindow = 0x00000080;
    private readonly DispatcherTimer dismissTimer;
    private readonly DispatcherTimer pulseTimer;
    private int pulseStep;
    private bool closed;

    public PillWindow()
    {
        InitializeComponent();
        dismissTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(350) };
        dismissTimer.Tick += (_, _) => HideStatus();
        pulseTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(110) };
        pulseTimer.Tick += (_, _) =>
        {
            pulseStep++;
            SetBars((float)(0.25 + 0.2 * Math.Sin(pulseStep * 0.6)));
        };
        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            var existing = GetWindowLongPtr(hwnd, GwlExStyle).ToInt64();
            SetWindowLongPtr(hwnd, GwlExStyle, new IntPtr(existing | WsExNoActivate | WsExToolWindow));
        };
        Closed += (_, _) => { closed = true; dismissTimer.Stop(); pulseTimer.Stop(); };
    }

    public void ShowStatus(string text, string? detail = null, float level = 0)
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(() => ShowStatus(text, detail, level)); return; }
        if (closed) return;
        dismissTimer.Stop();
        pulseTimer.Stop();
        StateLabel.Text = text;
        DetailLabel.Text = detail ?? string.Empty;
        DetailLabel.Visibility = string.IsNullOrWhiteSpace(detail) ? Visibility.Collapsed : Visibility.Visible;
        SetBars(level);
        if (!IsVisible) Show();
        PositionOnActiveMonitor();
        if (text.Equals("Done", StringComparison.OrdinalIgnoreCase)) dismissTimer.Start();
        else if (!text.Contains("listen", StringComparison.OrdinalIgnoreCase)
            && !text.Contains("record", StringComparison.OrdinalIgnoreCase)) pulseTimer.Start();
    }

    public void UpdateLevel(float level)
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(() => UpdateLevel(level)); return; }
        if (!closed && IsVisible && !pulseTimer.IsEnabled) SetBars(level);
    }

    public void HideStatus()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(HideStatus); return; }
        dismissTimer.Stop(); pulseTimer.Stop();
        if (!closed) Hide();
    }

    private void SetBars(float level)
    {
        var magnitude = Math.Clamp(double.IsFinite(level) ? level : 0, 0, 1);
        var peak = 4 + 24 * Math.Sqrt(magnitude);
        Wave1.Height = Math.Max(4, peak * 0.45);
        Wave2.Height = Math.Max(4, peak * 0.72);
        Wave3.Height = peak;
        Wave4.Height = Math.Max(4, peak * 0.83);
        Wave5.Height = Math.Max(4, peak * 0.52);
    }

    private void PositionOnActiveMonitor()
    {
        // WorkArea is in physical pixels; WPF window coordinates use device-independent units.
        var area = System.Windows.Forms.Screen.FromHandle(GetForegroundWindow()).WorkingArea;
        var source = PresentationSource.FromVisual(this);
        var transform = source?.CompositionTarget?.TransformFromDevice ?? System.Windows.Media.Matrix.Identity;
        var topLeft = transform.Transform(new Point(area.Left, area.Top));
        var bottomRight = transform.Transform(new Point(area.Right, area.Bottom));
        Left = topLeft.X + (bottomRight.X - topLeft.X - Width) / 2;
        Top = bottomRight.Y - Height - 22;
    }

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr value);
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
}
