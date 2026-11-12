using System;
using System.ComponentModel;
using System.Threading.Tasks;
using System.Windows;

namespace Voice.Windows;

public partial class MainWindow : Window
{
    private bool closeApproved;
    private bool closeInProgress;
    public Func<Task<bool>>? BeforeCloseAsync { get; set; }

    public MainWindow(object? model = null)
    {
        InitializeComponent();
        var available = SystemParameters.WorkArea;
        MinWidth = Math.Min(MinWidth, available.Width);
        MinHeight = Math.Min(MinHeight, available.Height);
        Width = Math.Min(Width, available.Width);
        Height = Math.Min(Height, available.Height);
        if (model is not null) DataContext = model;
        Closing += OnClosing;
    }

    private async void OnClosing(object? sender, CancelEventArgs e)
    {
        if (closeApproved || BeforeCloseAsync is null) return;
        e.Cancel = true;
        if (closeInProgress) return;
        closeInProgress = true;
        try
        {
            if (await BeforeCloseAsync())
            {
                closeApproved = true;
                Close();
            }
        }
        catch (Exception error)
        {
            MessageBox.Show(this, "Voice could not finish saving. The window has stayed open.\n\n" + error.Message,
                "Voice", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally { closeInProgress = false; }
    }
}
