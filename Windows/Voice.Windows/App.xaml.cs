using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Voice.Windows.Platform;
using Voice.Windows.ViewModels;

namespace Voice.Windows;

public partial class App : Application
{
    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args.Length == 2 && e.Args[0] == "--render-preview")
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            try { await RenderPreviewsAsync(e.Args[1]); Shutdown(0); }
            catch (Exception error) { Console.Error.WriteLine(error); Shutdown(1); }
            return;
        }
        if (e.Args.Contains("--smoke-test", StringComparer.Ordinal))
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            try
            {
                // Exercise XAML/resource construction without starting a microphone,
                // workers, model downloads, or a persistent user-data store.
                var window = new MainWindow();
                window.ApplyTemplate();
                foreach (var engine in new[] { "localvoice-speech.exe", "localvoice-editor.exe", "localvoice-diarizer.exe" })
                    if (!File.Exists(Path.Combine(AppContext.BaseDirectory, "engines", engine)))
                        throw new FileNotFoundException("A required packaged engine is missing.", engine);
                Console.WriteLine("Platform checks passed: " + PlatformSelfTests.Run());
                window.Close();
                Shutdown(0);
            }
            catch (Exception error)
            {
                Console.Error.WriteLine(error);
                Shutdown(1);
            }
            return;
        }

        try
        {
            var model = new VoiceViewModel();
            var window = new MainWindow(model);
            MainWindow = window;
            window.BeforeCloseAsync = async () => { await model.ShutdownAsync(); return true; };
            window.Show();
            await model.InitializeAsync();
        }
        catch (Exception error)
        {
            MessageBox.Show("Voice could not start.\n\n" + error.Message, "Voice", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }

    private static async Task RenderPreviewsAsync(string destination)
    {
        // This diagnostic path is used only by the build workflow. It never
        // constructs VoiceViewModel, records audio, or opens the user's store.
        Directory.CreateDirectory(destination);
        var previewMeeting = new PreviewMeeting
        {
            Title = "Meeting workspace preview", DateText = "Synthetic UI test data", DurationText = "3 min",
            Notes = "Use this space for your own notes. This is a layout test fixture.",
            Transcript = "[00:00:00 · Speaker 1]\nThis is a synthetic preview of a speaker-labelled transcript.\n\n[00:00:12 · Speaker 2]\nMeeting transcripts remain on your PC.",
            Summary = "This field can hold an editable meeting summary. No meeting was recorded for this UI preview."
        };
        var window = new MainWindow { Width = 1280, Height = 850, ShowActivated = false };
        window.Show();
        var pages = new[] { "dictation", "notetaker", "dictionary", "history", "settings" };
        for (var section = 0; section < pages.Length; section++)
        {
            window.DataContext = new PreviewData
            {
                SelectedSectionIndex = section,
                StatusText = "UI preview · synthetic data", StatusDetail = "No microphone, model download or personal data store was opened.",
                DictationButtonText = "Start dictation", IsBusy = false, HasMeetingPrompt = false,
                ModeIndex = 0, MuteDuringDictation = false, SuggestMeetings = true, KeepAudio = true, MeetingOnlineMode = true,
                CanEditMeeting = true, AnalyzeSpeakers = true, GenerateSummary = false,
                DictionaryText = "", SpeechStatus = "Not downloaded", EditorStatus = "Not downloaded", SpeakerStatus = "Not downloaded",
                DownloadProgress = 0, DownloadStatus = "", SpeakerNamesText = "Speaker 1 = First speaker\nSpeaker 2 = Second speaker",
                SpeechModelOptions = new[] { new PreviewSpeechModel("turbo", "Large v3 turbo · 1.6 GB") }, SelectedSpeechModelId = "turbo",
                Meetings = new List<PreviewMeeting> { previewMeeting }, SelectedMeeting = previewMeeting,
                History = new List<object>()
            };
            window.UpdateLayout();
            await window.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Render);
            var visual = (FrameworkElement)window.Content;
            var image = new RenderTargetBitmap((int)Math.Ceiling(visual.ActualWidth), (int)Math.Ceiling(visual.ActualHeight), 96, 96, PixelFormats.Pbgra32);
            image.Render(visual);
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
            using var file = File.Create(Path.Combine(destination, pages[section] + ".png"));
            encoder.Save(file);
        }
        window.Close();
    }

    private sealed record PreviewSpeechModel(string Id, string Name);
    private sealed class PreviewMeeting
    {
        public string Title { get; set; } = "";
        public string DateText { get; set; } = "";
        public string DurationText { get; set; } = "";
        public string Notes { get; set; } = "";
        public string Transcript { get; set; } = "";
        public string Summary { get; set; } = "";
    }
    private sealed class PreviewData
    {
        public int SelectedSectionIndex { get; set; }
        public string StatusText { get; set; } = "";
        public string StatusDetail { get; set; } = "";
        public string DictationButtonText { get; set; } = "";
        public bool IsBusy { get; set; }
        public bool HasMeetingPrompt { get; set; }
        public string MeetingPromptText { get; set; } = "";
        public int ModeIndex { get; set; }
        public bool MuteDuringDictation { get; set; }
        public bool SuggestMeetings { get; set; }
        public bool KeepAudio { get; set; }
        public bool MeetingOnlineMode { get; set; }
        public bool CanEditMeeting { get; set; }
        public bool AnalyzeSpeakers { get; set; }
        public bool GenerateSummary { get; set; }
        public string DictionaryText { get; set; } = "";
        public string SpeechStatus { get; set; } = "";
        public string EditorStatus { get; set; } = "";
        public string SpeakerStatus { get; set; } = "";
        public int DownloadProgress { get; set; }
        public string DownloadStatus { get; set; } = "";
        public string SpeakerNamesText { get; set; } = "";
        public PreviewSpeechModel[] SpeechModelOptions { get; set; } = [];
        public string SelectedSpeechModelId { get; set; } = "";
        public List<PreviewMeeting> Meetings { get; set; } = [];
        public PreviewMeeting? SelectedMeeting { get; set; }
        public List<object> History { get; set; } = [];
    }
}
