using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace Voice.Windows;

/// <summary>A visible invitation to record. Showing it never starts capture or takes focus.</summary>
public sealed class MeetingPromptWindow : Window
{
    private readonly DispatcherTimer expiry = new() { Interval = TimeSpan.FromSeconds(45) };
    private readonly Button dismiss = new() { Content = "Not now" };

    public MeetingPromptWindow()
    {
        Title = "Voice · Meeting detected";
        Width = 420; Height = 174;
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true; Background = Brushes.Transparent;
        ShowActivated = false; ShowInTaskbar = false; Topmost = true;
        var panel = new StackPanel();
        panel.Children.Add(new TextBlock { Text = "Voice", FontSize = 12, FontWeight = FontWeights.SemiBold,
            Foreground = (Brush)FindResource("AccentBrush"), Margin = new Thickness(0, 0, 0, 7) });
        var message = new TextBlock { FontSize = 17, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 16) };
        message.SetBinding(TextBlock.TextProperty, new Binding("MeetingPromptText"));
        panel.Children.Add(message);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        var start = new Button { Content = "Start notes", Style = (Style)FindResource("PrimaryButton") };
        start.SetBinding(Button.CommandProperty, new Binding("AcceptMeetingPromptCommand"));
        dismiss.SetBinding(Button.CommandProperty, new Binding("DismissMeetingPromptCommand"));
        buttons.Children.Add(start); buttons.Children.Add(dismiss); panel.Children.Add(buttons);
        Content = new Border { Background = (Brush)FindResource("SurfaceBrush"),
            BorderBrush = (Brush)FindResource("BorderBrush"), BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(18), Padding = new Thickness(22, 18, 22, 18), Child = panel };
        expiry.Tick += (_, _) => Dismiss();
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) { e.Handled = true; Dismiss(); } };
        Closed += (_, _) => expiry.Stop();
    }

    public void ShowSuggestion(object model)
    {
        DataContext = model;
        if (!IsVisible) Show();
        var area = System.Windows.Forms.Screen.FromHandle(GetForegroundWindow()).WorkingArea;
        var transform = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var topLeft = transform.Transform(new Point(area.Left, area.Top));
        var bottomRight = transform.Transform(new Point(area.Right, area.Bottom));
        Left = Math.Max(topLeft.X, bottomRight.X - Width - 20);
        Top = Math.Max(topLeft.Y, bottomRight.Y - Height - 20);
        expiry.Stop(); expiry.Start();
    }

    public void HideSuggestion() { expiry.Stop(); Hide(); }

    private void Dismiss()
    {
        HideSuggestion();
        // Invoke the same dismissal as the main window, so the detector's cooldown agrees.
        var command = dismiss.Command;
        if (command?.CanExecute(null) == true) command.Execute(null);
    }

    [DllImport("user32.dll")]
    private static extern nint GetForegroundWindow();
}
