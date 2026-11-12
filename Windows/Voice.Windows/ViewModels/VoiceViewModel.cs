using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using Microsoft.Win32;
using Voice.Core;
using Voice.Windows.Platform;
using WpfApplication = System.Windows.Application;
using WpfClipboard = System.Windows.Clipboard;

namespace Voice.Windows.ViewModels;

public sealed class VoiceViewModel : Bindable
{
    private readonly AppPaths paths = new();
    private readonly LocalStore store;
    private readonly ModelManager models;
    private readonly VoiceEngine engine;
    private readonly GlobalHotkey hotkey = new();
    private readonly PasteService paste = new();
    private readonly AudioDucker ducker = new();
    private readonly MeetingDetector detector = new();
    private readonly PillWindow pill = new();
    private readonly Dispatcher dispatcher = WpfApplication.Current.Dispatcher;
    private VoiceSettings settings = new();
    private List<VocabularyEntry> vocabulary = [];
    private AudioRecorder? recorder;
    private CancellationTokenSource? cancellation;
    private PasteTarget? pasteTarget;
    private VoiceSettings? activeSettings;
    private string? sessionDirectory;
    private MeetingItem? activeMeeting;
    private MeetingSuggestion? suggestion;
    private bool initialized, shuttingDown;
    private string operation = "idle";
    private int generation;
    private Task currentJob = Task.CompletedTask;

    public VoiceViewModel()
    {
        store = new(paths); models = new(paths); engine = new(paths, Path.Combine(AppContext.BaseDirectory, "engines"));
        ToggleDictationCommand = Command(() => ToggleDictationAsync());
        CancelCommand = Command(CancelAsync);
        StartMeetingCommand = Command(StartMeetingAsync);
        StopMeetingCommand = Command(StopMeetingAsync);
        RetryMeetingCommand = Command(RetryMeetingAsync);
        DownloadSpeechCommand = Command(() => DownloadAsync("speech"));
        DownloadEditorCommand = Command(() => DownloadAsync("editor"));
        DownloadSpeakerCommand = Command(() => DownloadAsync("speakers"));
        SaveDictionaryCommand = Command(SaveDictionaryAsync);
        SaveMeetingCommand = Command(() => { SaveSelectedMeeting(); ShowStatus("Saved", "Meeting changes saved on this PC."); return Task.CompletedTask; });
        SaveSpeakerNamesCommand = Command(SaveSpeakerNamesAsync);
        CopyMeetingCommand = Command(() => { SaveSelectedMeeting(); if (SelectedMeeting != null) WpfClipboard.SetText(SelectedMeeting.ExportText); return Task.CompletedTask; });
        ExportMeetingCommand = Command(ExportMeetingAsync);
        CopyHistoryCommand = new ActionCommand(p => Run(() => { if (p is string text && text.Length > 0) WpfClipboard.SetText(text); return Task.CompletedTask; }));
        OpenDataFolderCommand = Command(() => { Process.Start(new ProcessStartInfo("explorer.exe", paths.Root) { UseShellExecute = true }); return Task.CompletedTask; });
        OpenMicrophoneSettingsCommand = Command(() => { Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true }); return Task.CompletedTask; });
        AcceptMeetingPromptCommand = Command(async () => { MeetingOnlineMode = true; DismissPrompt(); await StartMeetingAsync(); });
        DismissMeetingPromptCommand = Command(() => { DismissPrompt(); return Task.CompletedTask; });
        engine.StatusChanged += text =>
        {
            var current = generation;
            dispatcher.BeginInvoke(() => { if (generation == current && operation == "dictation-processing") { ShowStatus(text, StatusDetail); pill.ShowStatus("Typing", text, 0); } });
        };
    }

    public ICommand ToggleDictationCommand { get; }
    public ICommand CancelCommand { get; }
    public ICommand StartMeetingCommand { get; }
    public ICommand StopMeetingCommand { get; }
    public ICommand RetryMeetingCommand { get; }
    public ICommand DownloadSpeechCommand { get; }
    public ICommand DownloadEditorCommand { get; }
    public ICommand DownloadSpeakerCommand { get; }
    public ICommand SaveDictionaryCommand { get; }
    public ICommand SaveMeetingCommand { get; }
    public ICommand SaveSpeakerNamesCommand { get; }
    public ICommand CopyMeetingCommand { get; }
    public ICommand ExportMeetingCommand { get; }
    public ICommand CopyHistoryCommand { get; }
    public ICommand OpenDataFolderCommand { get; }
    public ICommand OpenMicrophoneSettingsCommand { get; }
    public ICommand AcceptMeetingPromptCommand { get; }
    public ICommand DismissMeetingPromptCommand { get; }
    public ObservableCollection<MeetingItem> Meetings { get; } = [];
    public ObservableCollection<HistoryItem> History { get; } = [];
    public string VersionText => "0.7.0 · Windows preview";
    public string ShortcutText => "Ctrl + Alt + Space";
    public sealed record ModelOption(string Id, string Name);
    public IReadOnlyList<ModelOption> SpeechModelOptions { get; } = [new("turbo", "Large v3 Turbo · 1.62 GB"), new("base.en", "Lightweight English · 148 MB"), new("large", "Large v3 · 3.10 GB")];
    public string SelectedSpeechModelId { get => settings.SpeechModelId; set { if (!IsBusy && ModelCatalog.SpeechModels.Any(m => m.Id == value)) { settings.SpeechModelId = value; Changed(); SaveSettings(); RefreshModels(); } } }
    private string statusText = "Welcome to Voice", statusDetail = "Your voice. On your PC.";
    public string StatusText { get => statusText; private set => Set(ref statusText, value); }
    public string StatusDetail { get => statusDetail; private set => Set(ref statusDetail, value); }
    public bool IsBusy => operation != "idle";
    public bool IsRecording => operation == "dictation-recording";
    public bool IsMeetingRecording => operation == "meeting-recording";
    public bool CanEditMeeting => !IsBusy;
    public string DictationButtonText => IsRecording ? "Finish dictation" : "Start dictation";
    private int selectedSectionIndex;
    public int SelectedSectionIndex { get => selectedSectionIndex; set { try { SaveSelectedMeeting(); Set(ref selectedSectionIndex, value); } catch (Exception e) { ShowError(e); } } }
    public int ModeIndex { get => settings.CleanMode ? 1 : 0; set { settings.CleanMode = value == 1; Changed(); SaveSettings(); } }
    public bool MuteDuringDictation { get => settings.MuteWhileDictating; set { settings.MuteWhileDictating = value; Changed(); SaveSettings(); } }
    public bool SuggestMeetings { get => settings.SuggestMeetings; set { settings.SuggestMeetings = value; detector.Enabled = value; Changed(); SaveSettings(); } }
    public bool KeepAudio { get => settings.KeepMeetingAudio; set { settings.KeepMeetingAudio = value; Changed(); SaveSettings(); } }
    public bool AnalyzeSpeakers { get => settings.AnalyzeSpeakers; set { settings.AnalyzeSpeakers = value; Changed(); SaveSettings(); } }
    public bool GenerateSummary { get => settings.GenerateSummary; set { settings.GenerateSummary = value; Changed(); SaveSettings(); } }
    public bool MeetingOnlineMode { get; set; } = true;
    private string dictionaryText = "";
    public string DictionaryText { get => dictionaryText; set => Set(ref dictionaryText, value); }
    private string speakerNamesText = "";
    public string SpeakerNamesText { get => speakerNamesText; set => Set(ref speakerNamesText, value); }
    private MeetingItem? selectedMeeting;
    public MeetingItem? SelectedMeeting
    {
        get => selectedMeeting;
        set
        {
            try
            {
                SaveSelectedMeeting();
                if (Set(ref selectedMeeting, value))
                    SpeakerNamesText = value == null ? "" : string.Join("\n", value.Record.Transcript.Select(s => s.SpeakerLabel).Distinct().Select(s => $"{s} = {value.Record.SpeakerNames.GetValueOrDefault(s, s)}"));
            }
            catch (Exception e) { ShowError(e); }
        }
    }
    public bool HasMeetingPrompt => suggestion != null;
    public string MeetingPromptText => suggestion == null ? "" : $"Meeting detected in {suggestion.AppName}. Start notes?";
    public string SpeechStatus => models.HasSpeech(settings.SpeechModelId) ? "Downloaded · ready for local dictation" : "Download the selected speech model";
    public string EditorStatus => models.HasEditor ? "Downloaded · Clean mode and summaries available" : "Optional: Clean mode and summaries · 4.68 GB";
    public string SpeakerStatus => models.HasSpeakers ? "Downloaded · speaker analysis available" : "Optional: speaker analysis · approximately 42 MB download";
    private double downloadProgress;
    private string downloadStatus = "";
    public double DownloadProgress { get => downloadProgress; private set => Set(ref downloadProgress, value); }
    public string DownloadStatus { get => downloadStatus; private set => Set(ref downloadStatus, value); }

    public Task InitializeAsync()
    {
        try
        {
            settings = store.LoadSettings(); vocabulary = store.LoadVocabulary();
            DictionaryText = string.Join("\n", vocabulary.Select(v => v.Heard == v.Preferred ? v.Preferred : $"{v.Heard} = {v.Preferred}"));
            foreach (var meeting in store.LoadMeetings())
            {
                var recovered = AudioRecorder.RecoverParts(Path.Combine(paths.MeetingDirectory(meeting.Id), "Audio"));
                foreach (var part in recovered)
                    if (!meeting.AudioParts.Any(p => p.Path == part.Path)) meeting.AudioParts.Add(new(part.Path, part.Source, part.StartSeconds, part.DurationSeconds));
                if (meeting.Status is "Recording" or "Transcribing" or "Identifying speakers" or "Summarising")
                {
                    meeting.Status = "Interrupted";
                    meeting.Error = "Voice stopped during this meeting. Flushed audio was recovered; choose Recover / retry.";
                    store.SaveMeeting(meeting);
                }
                Meetings.Add(new(meeting));
            }
            foreach (var entry in store.LoadHistory()) History.Add(new(entry));
            initialized = true;
            foreach (var p in new[] {nameof(ModeIndex),nameof(MuteDuringDictation),nameof(SuggestMeetings),nameof(KeepAudio),nameof(SelectedSpeechModelId),nameof(AnalyzeSpeakers),nameof(GenerateSummary)}) Changed(p);
            RefreshModels();
            hotkey.ToggleRequested += () => dispatcher.BeginInvoke(() => { var target = paste.CaptureTarget(); Run(() => ToggleDictationAsync(target)); });
            hotkey.CancelRequested += () => dispatcher.BeginInvoke(() => Run(CancelAsync));
            try { hotkey.Register(WpfApplication.Current.MainWindow); }
            catch (Exception e) { ShowStatus("Shortcut unavailable", e.Message + " You can still use the buttons in Voice."); }
            detector.Enabled = settings.SuggestMeetings;
            detector.Suggested += value => dispatcher.BeginInvoke(() =>
            {
                if (!IsBusy && settings.SuggestMeetings) { suggestion = value; Changed(nameof(HasMeetingPrompt)); Changed(nameof(MeetingPromptText)); }
            });
            detector.Start();
            if (!models.HasSpeech(settings.SpeechModelId)) { SelectedSectionIndex = 4; ShowStatus("Download your speech model", "Choose Download speech to get started. Audio processing stays on this PC."); }
            else if (StatusText != "Shortcut unavailable") ShowStatus("Ready", "Press Ctrl + Alt + Space to start, speak, then press it again to paste.");
        }
        catch (Exception error) { initialized = false; ShowError(error); }
        return Task.CompletedTask;
    }

    private ICommand Command(Func<Task> action) => new ActionCommand(_ => Run(action));
    private async void Run(Func<Task> action)
    {
        if (shuttingDown) return;
        try { await action(); }
        catch (OperationCanceledException) { ShowStatus("Cancelled", "Ready when you are."); }
        catch (Exception error) { ShowError(error); }
    }
    private void State(string value)
    {
        operation = value;
        foreach (var p in new[] {nameof(IsBusy),nameof(IsRecording),nameof(IsMeetingRecording),nameof(CanEditMeeting),nameof(DictationButtonText)}) Changed(p);
        hotkey.SetCancellationEnabled(IsBusy);
        detector.SetBusy(IsBusy);
        CommandManager.InvalidateRequerySuggested();
    }
    private bool ReadyToStart()
    {
        if (!initialized) { ShowStatus("Setup needs attention", "Resolve the startup message before recording."); return false; }
        if (IsBusy) { ShowStatus(StatusText, "Finish or cancel the current activity first."); return false; }
        if (!models.HasSpeech(settings.SpeechModelId)) { SelectedSectionIndex = 4; ShowStatus("Download speech first", "Use Settings to download your local speech model."); return false; }
        return true;
    }
    private VoiceSettings SnapshotSettings() => new()
    {
        SpeechModelId = settings.SpeechModelId, Language = settings.Language, CleanMode = settings.CleanMode,
        MuteWhileDictating = settings.MuteWhileDictating, SuggestMeetings = settings.SuggestMeetings,
        KeepMeetingAudio = settings.KeepMeetingAudio, AnalyzeSpeakers = settings.AnalyzeSpeakers, GenerateSummary = settings.GenerateSummary
    };
    private void Begin(string state)
    {
        cancellation?.Dispose(); cancellation = new(); generation++; State(state); DismissPrompt();
    }
    private void Finish()
    {
        ducker.Restore(); cancellation?.Dispose(); cancellation = null; recorder = null; activeMeeting = null;
        State("idle"); RefreshModels();
    }

    private async Task ToggleDictationAsync(PasteTarget? target = null)
    {
        if (IsRecording) { currentJob = FinishDictationAsync(); await currentJob; return; }
        if (!ReadyToStart()) return;
        if (settings.CleanMode && !models.HasEditor) { SelectedSectionIndex = 4; ShowStatus("Clean mode needs its editor model", "Download the optional editor, or select Fast mode."); return; }
        currentJob = StartDictationCoreAsync(target); await currentJob;
    }
    private async Task StartDictationCoreAsync(PasteTarget? target)
    {
        Begin("dictation-starting");
        try
        {
            activeSettings = SnapshotSettings(); pasteTarget = target ?? paste.CaptureTarget();
            sessionDirectory = paths.NewSessionDirectory(); recorder = MakeRecorder();
            if (activeSettings.MuteWhileDictating) ducker.Mute();
            await recorder.StartAsync(sessionDirectory, false, cancellation!.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            State("dictation-recording"); ShowStatus("Listening", "Press Ctrl + Alt + Space again to finish. Escape cancels."); pill.ShowStatus("Listening", "Ctrl + Alt + Space to finish", 0);
        }
        catch { await StopCaptureBestEffortAsync(); Finish(); pill.HideStatus(); throw; }
    }
    private AudioRecorder MakeRecorder()
    {
        var capture = new AudioRecorder();
        var current = generation;
        capture.LevelChanged += (mic, system) => dispatcher.BeginInvoke(() => { if (generation == current && ReferenceEquals(recorder, capture) && IsRecording) pill.UpdateLevel(mic); });
        capture.Error += error => dispatcher.BeginInvoke(() =>
        {
            if (generation != current || !ReferenceEquals(recorder, capture) || shuttingDown) return;
            Run(async () => { await CancelAsync(); if (generation == current) ShowError(error); });
        });
        return capture;
    }
    private async Task FinishDictationAsync()
    {
        var token = cancellation!.Token; var current = generation;
        State("dictation-processing"); ShowStatus("Transcribing", "Processing on this PC. You can cancel with Escape."); pill.ShowStatus("Typing", "Processing locally", 0);
        try
        {
            var parts = await recorder!.StopAsync(); await recorder.DisposeAsync(); recorder = null; ducker.Restore();
            token.ThrowIfCancellationRequested();
            var combined = Path.Combine(sessionDirectory!, "dictation.f32");
            await using (var output = new FileStream(combined, FileMode.Create, FileAccess.Write, FileShare.None))
                foreach (var part in parts.Where(p => p.Source == "microphone").OrderBy(p => p.StartSeconds))
                { await using var input = File.OpenRead(part.Path); await input.CopyToAsync(output, token); }
            var result = await engine.TranscribeAsync(combined, activeSettings!, vocabulary.ToArray(), token);
            token.ThrowIfCancellationRequested();
            if (string.IsNullOrWhiteSpace(result.Text)) { ShowStatus("No speech found", "Try speaking a little closer to the microphone."); return; }
            var entry = new HistoryEntry(Guid.NewGuid(), DateTimeOffset.Now, result.Text, activeSettings!.CleanMode ? "Clean" : "Fast");
            History.Insert(0, new(entry)); store.SaveHistory(History.Select(h => h.Record));
            var pasted = pasteTarget == null ? null : await paste.PasteAsync(result.Text, pasteTarget, token);
            ShowStatus(pasted?.Pasted == true ? "Done" : "Text saved", result.Warning ?? pasted?.Message ?? "Copy your text from History.");
            pill.ShowStatus("Done", "Saved in History", 0);
            TryDeleteSession(sessionDirectory);
        }
        catch (OperationCanceledException) { ShowStatus("Cancelled", "The previous dictation will not paste."); pill.HideStatus(); }
        catch (Exception error) { ShowError(error); pill.HideStatus(); }
        finally
        {
            await StopCaptureBestEffortAsync(); Finish();
            _ = HidePillAfterAsync(current);
        }
    }
    private async Task HidePillAfterAsync(int current) { await Task.Delay(650); if (generation == current && !IsBusy) pill.HideStatus(); }

    private async Task StartMeetingAsync()
    {
        if (!ReadyToStart()) return;
        SaveSelectedMeeting(); currentJob = StartMeetingCoreAsync(); await currentJob;
    }
    private async Task StartMeetingCoreAsync()
    {
        Begin("meeting-starting");
        var record = new MeetingRecord { Title = "Meeting · " + DateTime.Now.ToString("d MMM yyyy HH:mm"), Status = "Recording" };
        try
        {
        activeSettings = SnapshotSettings();
        store.SaveMeeting(record); activeMeeting = new(record); Meetings.Insert(0, activeMeeting); SelectedMeeting = activeMeeting; SelectedSectionIndex = 1;
        sessionDirectory = Path.Combine(paths.MeetingDirectory(record.Id), "Audio");
        recorder = MakeRecorder();
        var captureGeneration = generation;
        recorder.PartCompleted += part => dispatcher.BeginInvoke(() =>
        {
            if (generation != captureGeneration) return;
            try
            {
                if (!record.AudioParts.Any(p => p.Path == part.Path)) record.AudioParts.Add(new(part.Path, part.Source, part.StartSeconds, part.DurationSeconds));
                store.SaveMeeting(record);
            }
            catch (Exception error) { ShowError(error); Run(CancelAsync); }
        });
            await recorder.StartAsync(sessionDirectory, MeetingOnlineMode, cancellation!.Token);
            cancellation.Token.ThrowIfCancellationRequested(); State("meeting-recording");
            ShowStatus("Recording meeting", MeetingOnlineMode ? "Microphone and PC playback are being recorded. Stop when the meeting ends." : "Recording this room through the microphone.");
        }
        catch (Exception error)
        {
            try { record.Status = "Interrupted"; record.Error = error.Message; store.SaveMeeting(record); }
            finally { await StopCaptureBestEffortAsync(); Finish(); }
            throw;
        }
    }
    private async Task StopMeetingAsync()
    {
        if (!IsMeetingRecording) return;
        currentJob = CompleteMeetingAsync(); await currentJob;
    }
    private async Task CompleteMeetingAsync()
    {
        var item = activeMeeting!; var token = cancellation!.Token;
        State("meeting-processing"); ShowStatus("Saving meeting", "The recording is kept on this PC.");
        try
        {
            var parts = await recorder!.StopAsync(); await recorder.DisposeAsync(); recorder = null;
            item.Record.AudioParts = parts.Select(p => new AudioPart(p.Path, p.Source, p.StartSeconds, p.DurationSeconds)).ToList();
            item.Record.Status = "Recorded"; store.SaveMeeting(item.Record); item.Refresh();
            await ProcessMeetingAsync(item, token);
        }
        catch (OperationCanceledException) { item.Record.Status = "Interrupted"; item.Record.Error = "Processing cancelled. Saved audio can be retried."; store.SaveMeeting(item.Record); ShowStatus("Meeting saved", item.Record.Error); }
        catch (Exception error) { item.Record.Status = "Needs attention"; item.Record.Error = error.Message; store.SaveMeeting(item.Record); ShowError(error); }
        finally { item.Refresh(); await StopCaptureBestEffortAsync(); Finish(); }
    }
    private async Task ProcessMeetingAsync(MeetingItem item, CancellationToken token)
    {
        var current = generation;
        var progress = new Progress<string>(text => { if (generation == current && IsBusy) { ShowStatus(text, "You can leave Voice open while it works locally."); item.Refresh(); } });
        await engine.ProcessMeetingAsync(item.Record, activeSettings!, vocabulary.ToArray(), progress, token);
        store.SaveMeeting(item.Record); item.Refresh();
        ShowStatus("Meeting saved", item.Record.Error ?? "Transcript and available notes are ready.");
    }
    private async Task RetryMeetingAsync()
    {
        if (!ReadyToStart() || SelectedMeeting == null) return;
        SaveSelectedMeeting(); var item = SelectedMeeting;
        foreach (var part in AudioRecorder.RecoverParts(Path.Combine(paths.MeetingDirectory(item.Record.Id), "Audio")))
            if (!item.Record.AudioParts.Any(p => p.Path == part.Path)) item.Record.AudioParts.Add(new(part.Path, part.Source, part.StartSeconds, part.DurationSeconds));
        if (item.Record.AudioParts.Count == 0 || !item.Record.AudioParts.Any(p => File.Exists(p.Path))) { ShowStatus("Audio unavailable", "This meeting has no retained audio to process."); return; }
        Begin("meeting-processing"); activeSettings = SnapshotSettings(); activeMeeting = item;
        currentJob = RetryCoreAsync(item, cancellation!.Token); await currentJob;
    }
    private async Task RetryCoreAsync(MeetingItem item, CancellationToken token)
    {
        try { await ProcessMeetingAsync(item, token); }
        catch (OperationCanceledException) { item.Record.Status = "Interrupted"; item.Record.Error = "Processing cancelled. Saved audio is available for retry."; store.SaveMeeting(item.Record); ShowStatus("Cancelled", item.Record.Error); }
        catch (Exception error) { item.Record.Status = "Needs attention"; item.Record.Error = error.Message; store.SaveMeeting(item.Record); ShowError(error); }
        finally { item.Refresh(); Finish(); }
    }
    private async Task CancelAsync()
    {
        if (!IsBusy) return;
        var previous = operation;
        cancellation?.Cancel(); engine.Cancel(); ducker.Restore(); pill.HideStatus();
        if (previous == "dictation-recording")
        {
            State("cancelling"); await StopCaptureBestEffortAsync(); TryDeleteSession(sessionDirectory); Finish();
            ShowStatus("Cancelled", "Ready for a new dictation.");
        }
        else if (previous == "meeting-recording")
        {
            var item = activeMeeting!; State("cancelling");
            try
            {
                var parts = await recorder!.StopAsync(); await recorder.DisposeAsync(); recorder = null;
                item.Record.AudioParts = parts.Select(p => new AudioPart(p.Path, p.Source, p.StartSeconds, p.DurationSeconds)).ToList();
                item.Record.Status = "Interrupted"; item.Record.Error = "Recording stopped. Choose Recover / retry to process the retained audio.";
                store.SaveMeeting(item.Record); item.Refresh(); ShowStatus("Meeting audio saved", item.Record.Error);
            }
            finally { await StopCaptureBestEffortAsync(); Finish(); }
        }
    }
    private async Task StopCaptureBestEffortAsync()
    {
        var capture = recorder; recorder = null;
        if (capture == null) return;
        try { await capture.StopAsync(); } catch { /* Original capture error is reported by the owning operation. */ }
        await capture.DisposeAsync();
    }

    private async Task DownloadAsync(string kind)
    {
        if (!initialized || IsBusy) return;
        Begin("downloading"); var token = cancellation!.Token;
        var current = generation;
        ShowStatus("Downloading model", "This is a one-time download. Cancel keeps existing verified models.");
        var progress = new Progress<ModelProgress>(p => { if (generation == current && operation == "downloading") { DownloadProgress = 100 * (p.Fraction ?? 0); DownloadStatus = p.Message; } });
        currentJob = DownloadCoreAsync(kind, progress, token); await currentJob;
    }
    private async Task DownloadCoreAsync(string kind, IProgress<ModelProgress> progress, CancellationToken token)
    {
        try
        {
            if (kind == "speech") await models.EnsureSpeechAsync(settings.SpeechModelId, progress, token);
            else if (kind == "editor") await models.EnsureEditorAsync(progress, token);
            else await models.EnsureSpeakersAsync(progress, token);
            DownloadProgress = 100; DownloadStatus = "Verified and ready"; ShowStatus("Model ready", "You can now use it offline.");
        }
        catch (OperationCanceledException) { DownloadStatus = "Download cancelled"; ShowStatus("Cancelled", "Existing verified models are unchanged."); }
        catch (Exception error) { DownloadStatus = error.Message; ShowError(error); }
        finally { Finish(); }
    }
    private void RefreshModels() { Changed(nameof(SpeechStatus)); Changed(nameof(EditorStatus)); Changed(nameof(SpeakerStatus)); }
    private void SaveSettings() { if (initialized) try { store.SaveSettings(settings); } catch (Exception e) { ShowError(e); } }
    private Task SaveDictionaryAsync()
    {
        var entries = new List<VocabularyEntry>();
        foreach (var line in DictionaryText.Split('\n').Select(s => s.Trim()).Where(s => s.Length > 0))
        {
            var pair = line.Split('=', 2, StringSplitOptions.TrimEntries);
            var heard = pair[0]; var preferred = pair.Length == 2 ? pair[1] : pair[0];
            if (heard.Length == 0 || preferred.Length == 0 || heard.Length > 200 || preferred.Length > 200) throw new InvalidOperationException("Use a word, or heard spelling = preferred spelling, on each line (maximum 200 characters each).");
            entries.Add(new(heard, preferred));
        }
        store.SaveVocabulary(entries); vocabulary = entries; ShowStatus("Dictionary saved", "These words will be used for your next dictation."); return Task.CompletedTask;
    }
    private Task SaveSpeakerNamesAsync()
    {
        if (IsBusy || SelectedMeeting == null) return Task.CompletedTask;
        var names = new Dictionary<string, string>();
        var valid = SelectedMeeting.Record.Transcript.Select(s => s.SpeakerLabel).ToHashSet();
        foreach (var line in SpeakerNamesText.Split('\n').Select(s => s.Trim()).Where(s => s.Length > 0))
        {
            var pair = line.Split('=', 2, StringSplitOptions.TrimEntries);
            if (pair.Length != 2 || !valid.Contains(pair[0]) || string.IsNullOrWhiteSpace(pair[1]) || pair[1].Length > 100) throw new InvalidOperationException("Use an existing speaker label = name on each line.");
            names[pair[0]] = pair[1];
        }
        SelectedMeeting.Record.SpeakerNames = names; store.SaveMeeting(SelectedMeeting.Record); SelectedMeeting.Refresh(); return Task.CompletedTask;
    }
    private void SaveSelectedMeeting() { if (initialized && SelectedMeeting != null && !IsBusy) store.SaveMeeting(SelectedMeeting.Record); }
    private Task ExportMeetingAsync()
    {
        SaveSelectedMeeting(); if (SelectedMeeting == null) return Task.CompletedTask;
        var dialog = new SaveFileDialog { Filter = "Text document|*.txt", FileName = "Voice-meeting.txt", AddExtension = true };
        if (dialog.ShowDialog() == true) File.WriteAllText(dialog.FileName, SelectedMeeting.ExportText);
        return Task.CompletedTask;
    }
    private void DismissPrompt()
    {
        if (suggestion != null) detector.Dismiss(suggestion.Key);
        suggestion = null; Changed(nameof(HasMeetingPrompt)); Changed(nameof(MeetingPromptText));
    }
    private void ShowStatus(string text, string detail) { StatusText = text; StatusDetail = detail; }
    private void ShowError(Exception error) => ShowStatus("Needs attention", error.Message);
    private void TryDeleteSession(string? directory)
    {
        if (directory == null) return;
        var full = Path.GetFullPath(directory);
        if (!full.StartsWith(paths.Sessions + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return;
        try { Directory.Delete(full, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
    public async Task ShutdownAsync()
    {
        if (shuttingDown) return;
        shuttingDown = true;
        try
        {
            SaveSelectedMeeting();
            await CancelAsync();
            // Startup, processing and downloads each own currentJob. Allow their
            // cleanup to finish before closing the pill or releasing hotkeys.
            try { await currentJob; }
            catch (OperationCanceledException) { }
            catch (Exception error) { ShowError(error); }
            await StopCaptureBestEffortAsync();
            SaveSelectedMeeting();
            if (initialized) { store.SaveSettings(settings); store.SaveHistory(History.Select(h => h.Record)); }
        }
        catch { shuttingDown = false; throw; } // Keep the app usable if saving needs a retry.
        try { await engine.DisposeAsync(); }
        finally { ducker.Dispose(); hotkey.Dispose(); detector.Dispose(); pill.Close(); }
    }
}
