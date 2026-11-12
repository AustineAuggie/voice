using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Voice.Core;

public sealed record DictationResult(string Text, string RawText, string? Warning);

/// <summary>Local processing shared by the Windows UI and tests. No networking is
/// performed here; downloading models is an explicit Settings action.</summary>
public sealed class VoiceEngine : IAsyncDisposable
{
    private readonly AppPaths paths;
    private readonly LocalStore store;
    private readonly ModelManager models;
    private readonly JsonLineWorker speech;
    private readonly JsonLineWorker editor;
    private readonly string diarizer;
    private readonly SemaphoreSlim work = new(1, 1);
    private readonly Dictionary<string, (long Length, DateTime Modified)> verified = [];
    private readonly SemaphoreSlim verification = new(1, 1);
    private readonly object speakerLock = new();
    private Process? speakerProcess;
    public event Action<string>? StatusChanged;

    public VoiceEngine(AppPaths paths, string engineDirectory)
    {
        this.paths = paths; store = new(paths); models = new(paths);
        speech = new(Path.Combine(engineDirectory, "localvoice-speech.exe"));
        editor = new(Path.Combine(engineDirectory, "localvoice-editor.exe"));
        diarizer = Path.Combine(engineDirectory, "localvoice-diarizer.exe");
    }

    public async Task WarmAsync(VoiceSettings settings, CancellationToken cancellationToken = default)
    {
        StatusChanged?.Invoke("Loading speech model…");
        var model = await RequireAsync(ModelCatalog.Speech(settings.SpeechModelId), cancellationToken).ConfigureAwait(false);
        await speech.WarmAsync(model, cancellationToken).ConfigureAwait(false);
        if (settings.CleanMode && models.HasEditor)
        {
            StatusChanged?.Invoke("Loading local editor…");
            var editorModel = await EditorModelAsync(cancellationToken).ConfigureAwait(false);
            await editor.WarmAsync(editorModel, cancellationToken).ConfigureAwait(false);
        }
        StatusChanged?.Invoke("Ready");
    }

    public async Task<DictationResult> TranscribeAsync(string raw16kFloatPath, VoiceSettings settings,
        IReadOnlyList<VocabularyEntry> vocabulary, CancellationToken cancellationToken = default)
    {
        await work.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ValidateAudio(raw16kFloatPath, 3600);
            var speechModel = await RequireAsync(ModelCatalog.Speech(settings.SpeechModelId), cancellationToken).ConfigureAwait(false);
            StatusChanged?.Invoke("Typing…");
            var response = await speech.RequestAsync(speechModel, new Dictionary<string, object?>
            {
                ["audio"] = raw16kFloatPath, ["language"] = Language(settings),
                ["prompt"] = TextCleanup.PreferredWords(vocabulary), ["accuracy"] = settings.CleanMode
            }, cancellationToken).ConfigureAwait(false);
            var raw = ReadText(response).Trim();
            var output = TextCleanup.Apply(raw, vocabulary);
            string? warning = null;
            if (settings.CleanMode && output.Length > 0)
            {
                if (!models.HasEditor) warning = "Clean mode needs the optional editor model. Fast text was retained; download the editor in Settings.";
                else
                {
                    try
                    {
                        StatusChanged?.Invoke("Cleaning text…");
                        var editorModel = await EditorModelAsync(cancellationToken).ConfigureAwait(false);
                        var edited = ReadText(await editor.RequestAsync(editorModel, new Dictionary<string, object?>
                        { ["text"] = output, ["vocabulary"] = TextCleanup.PreferredWords(vocabulary) }, cancellationToken).ConfigureAwait(false));
                        var valid = TextCleanup.ValidateEdited(edited, output);
                        if (valid is not null) output = TextCleanup.Vocabulary(valid, vocabulary);
                        else warning = "The local edit changed meaning or structure, so the original cleaned text was retained.";
                    }
                    catch (Exception e) when (e is not OperationCanceledException)
                    { warning = "The local editor could not finish. Fast text was retained. " + Friendly(e); }
                }
            }
            cancellationToken.ThrowIfCancellationRequested();
            return new(output, raw, warning);
        }
        finally { work.Release(); }
    }

    public async Task<MeetingRecord> ProcessMeetingAsync(MeetingRecord meeting, VoiceSettings settings,
        IReadOnlyList<VocabularyEntry> vocabulary, IProgress<string>? progress = null,
        CancellationToken cancellationToken = default)
    {
        await work.WaitAsync(cancellationToken).ConfigureAwait(false);
        var warnings = new List<string>();
        try
        {
            if (meeting.AudioParts.Count == 0) throw new InvalidOperationException("This meeting has no saved audio to process.");
            var parts = meeting.AudioParts.OrderBy(p => p.StartSeconds).ThenBy(p => p.Source, StringComparer.Ordinal).ToList();
            foreach (var part in parts) ValidatePart(part);
            var speechModel = await RequireAsync(ModelCatalog.Speech(settings.SpeechModelId), cancellationToken).ConfigureAwait(false);
            meeting.Error = null; meeting.Status = "Transcribing";
            var words = new List<MeetingWord>();
            // Keep the previous transcript until the first successful replacement chunk.
            // Subsequent chunks are saved one at a time for recovery after an interruption.
            var replacement = new List<TranscriptSegment>();
            for (var i = 0; i < parts.Count; ++i)
            {
                cancellationToken.ThrowIfCancellationRequested();
                progress?.Report($"Transcribing {i + 1} of {parts.Count}…");
                var part = parts[i];
                var value = await speech.RequestAsync(speechModel, new Dictionary<string, object?>
                {
                    ["audio"] = part.Path, ["language"] = Language(settings),
                    ["prompt"] = TextCleanup.PreferredWords(vocabulary), ["accuracy"] = settings.CleanMode,
                    ["timed"] = true
                }, cancellationToken).ConfigureAwait(false);
                var timed = ParseTimed(ReadText(value), part);
                words.AddRange(timed);
                var text = TextCleanup.Vocabulary(string.Concat(timed.Select(w => w.Text)), vocabulary).Trim();
                if (text.Length > 0) replacement.Add(new(part.StartSeconds, part.StartSeconds + part.DurationSeconds,
                    text, SourceLabel(part.Source)));
                meeting.Transcript = replacement.ToList();
                store.SaveMeeting(meeting);
            }
            if (settings.AnalyzeSpeakers && words.Count > 0)
            {
                meeting.Status = "Identifying speakers"; store.SaveMeeting(meeting);
                progress?.Report("Identifying speakers locally…");
                try
                {
                    var spans = await AnalyzeSpeakersAsync(meeting, parts, cancellationToken).ConfigureAwait(false);
                    meeting.Transcript = AssignSpeakers(words, spans, vocabulary);
                    store.SaveMeeting(meeting);
                }
                catch (Exception e) when (e is not OperationCanceledException)
                { warnings.Add("Speaker analysis did not finish. Source labels are shown and audio is retained for retry. " + Friendly(e)); }
            }
            if (settings.GenerateSummary && meeting.Transcript.Count > 0)
            {
                meeting.Status = "Summarising"; store.SaveMeeting(meeting);
                progress?.Report("Writing sourced meeting notes…");
                try { meeting.Summary = await SummariseAsync(meeting, cancellationToken).ConfigureAwait(false); }
                catch (Exception e) when (e is not OperationCanceledException)
                { warnings.Add("Summary did not finish. The transcript and audio are retained for retry. " + Friendly(e)); }
            }
            cancellationToken.ThrowIfCancellationRequested();
            meeting.Status = warnings.Count == 0 ? "Complete" : "Complete with warnings";
            meeting.Error = warnings.Count > 0 ? string.Join("\n", warnings) : null;
            store.SaveMeeting(meeting);
            // Deleting raw audio is only permitted after every requested stage succeeded.
            if (!settings.KeepMeetingAudio && warnings.Count == 0)
            {
                foreach (var part in parts)
                {
                    ValidateOwnedPath(part.Path);
                    try { File.Delete(part.Path); } catch (IOException) { }
                }
                meeting.AudioParts = parts.Where(p => File.Exists(p.Path)).ToList();
                store.SaveMeeting(meeting);
            }
            return meeting;
        }
        catch (OperationCanceledException)
        {
            meeting.Status = "Stopped"; meeting.Error = "Processing stopped. Saved audio and completed transcript are available for retry.";
            store.SaveMeeting(meeting); throw;
        }
        catch (Exception error)
        {
            meeting.Status = "Needs retry"; meeting.Error = Friendly(error);
            store.SaveMeeting(meeting); throw;
        }
        finally { work.Release(); }
    }

    public static string ExportMeeting(MeetingRecord meeting)
    {
        var result = new StringBuilder().AppendLine(meeting.Title).AppendLine(meeting.CreatedAt.ToString("f", CultureInfo.CurrentCulture));
        if (!string.IsNullOrWhiteSpace(meeting.Notes)) result.AppendLine().AppendLine("MY NOTES").AppendLine(meeting.Notes);
        if (!string.IsNullOrWhiteSpace(meeting.Summary)) result.AppendLine().AppendLine("SUMMARY").AppendLine(meeting.Summary);
        result.AppendLine().AppendLine("TRANSCRIPT");
        foreach (var part in meeting.Transcript)
        {
            var speaker = meeting.SpeakerNames.GetValueOrDefault(part.SpeakerLabel, part.SpeakerLabel);
            result.Append('[').Append(TimeSpan.FromSeconds(part.StartSeconds).ToString(@"hh\:mm\:ss", CultureInfo.InvariantCulture)).Append(" · ").Append(speaker).AppendLine("]").AppendLine(part.Text).AppendLine();
        }
        return result.ToString();
    }

    private async Task<string> RequireAsync(ModelAsset asset, CancellationToken cancellationToken)
    {
        await verification.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var path = models.GetAssetPath(asset); var info = new FileInfo(path);
            if (!info.Exists) throw new FileNotFoundException("Download the required model in Settings first: " + asset.Id);
            var signature = (info.Length, info.LastWriteTimeUtc);
            if (!verified.TryGetValue(path, out var prior) || prior != signature)
            {
                if (!await models.VerifyAsync(asset, cancellationToken).ConfigureAwait(false))
                    throw new InvalidDataException("Model verification failed. Download this model again in Settings: " + asset.Id);
                verified[path] = signature;
            }
            return path;
        }
        finally { verification.Release(); }
    }

    private async Task<string> EditorModelAsync(CancellationToken cancellationToken)
    {
        string? first = null;
        foreach (var asset in ModelCatalog.EditorModels)
        { var path = await RequireAsync(asset, cancellationToken).ConfigureAwait(false); first ??= path; }
        return first!;
    }

    private static string ReadText(JsonElement response)
    {
        if (!response.TryGetProperty("text", out var text) || text.ValueKind != JsonValueKind.String)
            throw new InvalidDataException("The local engine response did not contain text.");
        return text.GetString()!;
    }

    private void ValidateOwnedPath(string path)
    {
        var root = Path.GetFullPath(paths.Root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var full = Path.GetFullPath(path);
        if (!full.StartsWith(root, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
            throw new InvalidDataException("Meeting audio must remain inside Voice's local data folder.");
        var current = new FileInfo(full).Directory;
        while (current is not null && current.FullName.Length >= root.Length - 1)
        {
            if (current.LinkTarget is not null) throw new InvalidDataException("Meeting audio cannot use symbolic links.");
            current = current.Parent;
        }
        if (new FileInfo(full).LinkTarget is not null) throw new InvalidDataException("Meeting audio cannot use symbolic links.");
    }

    private void ValidatePart(AudioPart part)
    {
        ValidateOwnedPath(part.Path);
        if (!double.IsFinite(part.StartSeconds) || !double.IsFinite(part.DurationSeconds) || part.StartSeconds < 0 || part.DurationSeconds <= 0)
            throw new InvalidDataException("A meeting audio timestamp is invalid.");
        var duration = ValidateAudio(part.Path, 3600);
        if (Math.Abs(duration - part.DurationSeconds) > 0.05) throw new InvalidDataException("A meeting audio part is incomplete. The existing transcript is retained.");
    }

    private static double ValidateAudio(string path, int maxSeconds)
    {
        var file = new FileInfo(path);
        if (!file.Exists || file.Length <= 0 || file.Length % 4 != 0 || file.Length > 64_000L * maxSeconds)
            throw new InvalidDataException("The saved recording is missing, empty or invalid.");
        return file.Length / 64_000d;
    }

    internal sealed record MeetingWord(string Source, double Start, double End, string Text, bool TimingValid);
    internal sealed record SpeakerSpan(string Source, double Start, double End, int Speaker);
    private sealed record AudioMapping(string Source, double MeetingStart, double InputStart, double Duration);

    internal static List<MeetingWord> ParseTimed(string payload, AudioPart part)
    {
        using var document = JsonDocument.Parse(payload);
        var value = document.RootElement;
        if (value.GetProperty("version").GetInt32() != 1) throw new InvalidDataException("Unsupported word timing format.");
        var text = value.GetProperty("text").GetString() ?? "";
        var words = value.GetProperty("words");
        if (words.ValueKind != JsonValueKind.Array || words.GetArrayLength() > 50_000) throw new InvalidDataException("Invalid word timing response.");
        var result = new List<MeetingWord>(); var previous = 0d; var combined = new StringBuilder();
        foreach (var word in words.EnumerateArray())
        {
            var start = word.GetProperty("start").GetDouble(); var end = word.GetProperty("end").GetDouble();
            var piece = word.GetProperty("text").GetString() ?? "";
            var valid = !word.TryGetProperty("timingValid", out var flag) || flag.GetBoolean();
            if (!double.IsFinite(start) || !double.IsFinite(end) || start < previous || end < start || start < 0 || end > part.DurationSeconds + 0.05)
                throw new InvalidDataException("Invalid word timing response. Original audio is retained.");
            result.Add(new(part.Source, part.StartSeconds + start, part.StartSeconds + end, piece, valid && end > start));
            combined.Append(piece); previous = start;
        }
        if (combined.ToString() != text) throw new InvalidDataException("Timed text did not match the recognised transcript.");
        return result;
    }

    private async Task<List<SpeakerSpan>> AnalyzeSpeakersAsync(MeetingRecord meeting, IReadOnlyList<AudioPart> parts, CancellationToken cancellationToken)
    {
        if (!File.Exists(diarizer)) throw new FileNotFoundException("The speaker engine is missing; reinstall the complete Windows app folder.");
        var segmentation = await RequireAsync(ModelCatalog.SpeakerModels[0], cancellationToken).ConfigureAwait(false);
        var embedding = await RequireAsync(ModelCatalog.SpeakerModels[1], cancellationToken).ConfigureAwait(false);
        var folder = paths.MeetingDirectory(meeting.Id);
        var working = Path.Combine(folder, ".speakers-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(working);
        var input = Path.Combine(working, "input.f32"); var output = Path.Combine(working, "result.json");
        try
        {
            var mappings = new List<AudioMapping>(); long frames = 0;
            await using (var writer = new FileStream(input, FileMode.CreateNew, FileAccess.Write, FileShare.None, 131072, true))
            {
                foreach (var track in parts.GroupBy(p => p.Source))
                {
                    double? covered = null;
                    foreach (var part in track.OrderBy(p => p.StartSeconds))
                    {
                        cancellationToken.ThrowIfCancellationRequested(); ValidatePart(part);
                        var skipFrames = (long)Math.Round(Math.Max(0, (covered ?? part.StartSeconds) - part.StartSeconds) * 16000);
                        var partFrames = new FileInfo(part.Path).Length / 4;
                        if (skipFrames >= partFrames) continue;
                        if (mappings.Count > 0 && (covered is null || part.StartSeconds - covered > .3))
                        { await writer.WriteAsync(new byte[64_000], cancellationToken).ConfigureAwait(false); frames += 16_000; }
                        var count = partFrames - skipFrames;
                        if (frames + count > 6L * 3600 * 16000) throw new InvalidDataException("This meeting exceeds six hours of combined-source audio for one speaker pass.");
                        await using var reader = File.OpenRead(part.Path); reader.Position = skipFrames * 4;
                        await reader.CopyToAsync(writer, cancellationToken).ConfigureAwait(false);
                        mappings.Add(new(part.Source, part.StartSeconds + skipFrames / 16000d, frames / 16000d, count / 16000d));
                        frames += count; covered = Math.Max(covered ?? 0, part.StartSeconds + part.DurationSeconds);
                    }
                }
                await writer.FlushAsync(cancellationToken).ConfigureAwait(false);
            }
            if (frames == 0) return [];
            var child = new Process { StartInfo = new ProcessStartInfo(diarizer)
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true, WorkingDirectory = Path.GetDirectoryName(diarizer)! } };
            foreach (var argument in new[] { "--segmentation", segmentation, "--embedding", embedding, "--audio", input, "--output", output, "--threads", "2" }) child.StartInfo.ArgumentList.Add(argument);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(frames / 16000d * 2, 180, 14_400)));
            lock (speakerLock) { cancellationToken.ThrowIfCancellationRequested(); speakerProcess = child; child.Start(); }
            var errors = ReadTailAsync(child.StandardError);
            var stdout = ReadTailAsync(child.StandardOutput);
            try
            {
                using var cancellation = timeout.Token.Register(() => { try { if (!child.HasExited) child.Kill(true); } catch (InvalidOperationException) { } });
                await child.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
                var tail = await errors.ConfigureAwait(false); await stdout.ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();
                if (child.ExitCode != 0)
                {
                    var safe = tail.Replace(paths.Root, "<Voice data>", StringComparison.OrdinalIgnoreCase);
                    var user = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                    if (user.Length > 0) safe = safe.Replace(user, "~", StringComparison.OrdinalIgnoreCase);
                    await File.WriteAllTextAsync(Path.Combine(folder, "speaker-diagnostic.txt"), "Voice Windows speaker diagnostics\nExit: " + child.ExitCode + "\n" + safe, cancellationToken).ConfigureAwait(false);
                    throw new InvalidOperationException("The local speaker engine stopped (code " + child.ExitCode + "). Local diagnostics were saved in this meeting's folder.");
                }
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            { throw new TimeoutException("Speaker analysis timed out; retry with the retained audio."); }
            finally
            {
                lock (speakerLock) { if (ReferenceEquals(speakerProcess, child)) speakerProcess = null; }
                try { if (!child.HasExited) child.Kill(true); } catch (InvalidOperationException) { }
                child.Dispose();
            }
            var file = new FileInfo(output);
            if (!file.Exists || file.Length == 0 || file.Length > 32_000_000) throw new InvalidDataException("The speaker engine returned an invalid result file.");
            using var document = JsonDocument.Parse(await File.ReadAllTextAsync(output, cancellationToken).ConfigureAwait(false));
            var value = document.RootElement;
            var countSpeakers = value.GetProperty("num_speakers").GetInt32();
            if (value.GetProperty("sample_rate").GetInt32() != 16000 || countSpeakers < 0) throw new InvalidDataException("The speaker engine returned invalid model metadata.");
            var segments = value.GetProperty("segments");
            if (segments.GetArrayLength() > 200_000) throw new InvalidDataException("Too many speaker segments.");
            var spans = new List<SpeakerSpan>();
            foreach (var segment in segments.EnumerateArray())
            {
                var start = segment.GetProperty("start").GetDouble(); var end = segment.GetProperty("end").GetDouble();
                var speakerId = segment.GetProperty("speaker").GetInt32();
                if (!double.IsFinite(start) || !double.IsFinite(end) || start < 0 || end <= start || end > frames / 16000d + .1 || speakerId < 0 || speakerId >= countSpeakers)
                    throw new InvalidDataException("The speaker engine returned invalid segment timing.");
                foreach (var map in mappings.Where(m => m.InputStart < end && m.InputStart + m.Duration > start))
                {
                    var first = Math.Max(start, map.InputStart); var last = Math.Min(end, map.InputStart + map.Duration);
                    spans.Add(new(map.Source, map.MeetingStart + first - map.InputStart, map.MeetingStart + last - map.InputStart, speakerId));
                }
            }
            var oldDiagnostic = Path.Combine(folder, "speaker-diagnostic.txt");
            if (File.Exists(oldDiagnostic)) File.Delete(oldDiagnostic);
            return spans;
        }
        finally { try { Directory.Delete(working, recursive: true); } catch (IOException) { } }
    }

    internal static List<TranscriptSegment> AssignSpeakers(IReadOnlyList<MeetingWord> words, IReadOnlyList<SpeakerSpan> spans, IReadOnlyList<VocabularyEntry> vocabulary)
    {
        var labels = spans.OrderBy(s => s.Start).ThenBy(s => s.Source, StringComparer.Ordinal).Select(s => s.Speaker).Distinct()
            .Select((speaker, i) => (speaker, label: "Speaker " + (i + 1))).ToDictionary(x => x.speaker, x => x.label);
        var result = new List<TranscriptSegment>(); string? previousSource = null;
        foreach (var word in words.OrderBy(w => w.Start).ThenBy(w => w.Source, StringComparer.Ordinal))
        {
            var label = "Unclear speaker";
            if (word.TimingValid)
            {
                var overlaps = spans.Where(s => s.Source == word.Source && s.Start < word.End && s.End > word.Start)
                    .GroupBy(s => s.Speaker).Select(g => (Speaker: g.Key, Overlap: g.Sum(s => Math.Max(0, Math.Min(word.End, s.End) - Math.Max(word.Start, s.Start)))))
                    .OrderByDescending(x => x.Overlap).ToList();
                if (overlaps.Count > 0 && overlaps[0].Overlap >= (word.End - word.Start) * .5 &&
                    (overlaps.Count == 1 || overlaps[1].Overlap < overlaps[0].Overlap * .5)) label = labels[overlaps[0].Speaker];
            }
            if (result.Count > 0 && previousSource == word.Source && result[^1].SpeakerLabel == label &&
                word.Start - result[^1].EndSeconds < 1.5 && result[^1].Text.Length + word.Text.Length < 400)
            {
                var old = result[^1]; result[^1] = old with { EndSeconds = Math.Max(old.EndSeconds, word.End), Text = old.Text + word.Text };
            }
            else result.Add(new(word.Start, word.End, word.Text, label));
            previousSource = word.Source;
        }
        return result.Select(s => s with { Text = TextCleanup.Vocabulary(s.Text.Trim(), vocabulary) }).Where(s => s.Text.Length > 0).ToList();
    }

    private async Task<string> SummariseAsync(MeetingRecord meeting, CancellationToken cancellationToken)
    {
        var model = await EditorModelAsync(cancellationToken).ConfigureAwait(false);
        var excerpts = new List<(string Id, string Text)>();
        var part = 0;
        foreach (var segment in meeting.Transcript)
        {
            var text = segment.Text;
            while (text.Length > 0)
            {
                var length = Math.Min(1200, text.Length);
                if (length < text.Length) { var space = text.LastIndexOf(' ', length - 1, length); if (space > 300) length = space; }
                excerpts.Add(($"{meeting.Id:D}:{part++}", text[..length].Trim())); text = text[length..].TrimStart();
            }
        }
        var batches = new List<List<(string Id, string Text)>>(); var batch = new List<(string Id, string Text)>(); var size = 0;
        foreach (var excerpt in excerpts)
        {
            var required = excerpt.Text.Length + excerpt.Id.Length + 4;
            if (size + required > 4200 && batch.Count > 0) { batches.Add(batch); batch = []; size = 0; }
            batch.Add(excerpt); size += required;
        }
        if (batch.Count > 0) batches.Add(batch);
        var notes = new List<string>(); var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < batches.Count; ++i)
        {
            cancellationToken.ThrowIfCancellationRequested(); StatusChanged?.Invoke($"Writing notes {i + 1} of {batches.Count}…");
            var inputs = batches[i].ToDictionary(x => x.Id, x => x.Text);
            var text = string.Join("\n\n", batches[i].Select(x => $"[{x.Id}] {x.Text}"));
            var json = ReadText(await editor.RequestAsync(model, new Dictionary<string, object?> { ["task"] = "meeting", ["text"] = text }, cancellationToken).ConfigureAwait(false));
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Array || document.RootElement.GetArrayLength() > 6) throw new InvalidDataException("The local summary returned an invalid format.");
            foreach (var note in document.RootElement.EnumerateArray())
            {
                var kind = note.GetProperty("kind").GetString(); var content = note.GetProperty("text").GetString() ?? "";
                var source = note.GetProperty("source").GetString() ?? ""; var quote = note.GetProperty("quote").GetString() ?? "";
                if (kind is not ("summary" or "decision" or "action") || content.Length == 0 || content.Length > 1000 || quote.Length < 8 ||
                    !inputs.TryGetValue(source, out var original) || !original.Contains(quote, StringComparison.Ordinal))
                    throw new InvalidDataException("A generated note could not be verified against its source. The original transcript is retained.");
                foreach (var property in new[] { "owner", "due" })
                    if (note.TryGetProperty(property, out var named) && named.ValueKind != JsonValueKind.Null &&
                        (named.ValueKind != JsonValueKind.String || !quote.Contains(named.GetString()!, StringComparison.Ordinal)))
                        throw new InvalidDataException("A generated action named an unsupported owner or date.");
                if (seen.Add(content)) notes.Add($"{char.ToUpperInvariant(kind[0])}{kind[1..]}: {content}\n  Source: “{quote}”");
            }
        }
        return notes.Count == 0 ? "No supported decisions or action items were extracted. See the full transcript." : string.Join("\n\n", notes);
    }

    private static async Task<string> ReadTailAsync(StreamReader reader)
    {
        var value = new StringBuilder(); var buffer = new char[2048]; int count;
        while ((count = await reader.ReadAsync(buffer.AsMemory()).ConfigureAwait(false)) > 0)
        { value.Append(buffer, 0, count); if (value.Length > 16_384) value.Remove(0, value.Length - 16_384); }
        return value.ToString();
    }
    private static string SourceLabel(string source) => source == "microphone" ? "Microphone" : "System audio";
    private static string Language(VoiceSettings settings)
    {
        if (settings.SpeechModelId != "base.en") return settings.Language;
        if (settings.Language is not ("auto" or "en"))
            throw new InvalidOperationException("Base English supports English only. Choose Turbo or Large for another language.");
        return "en";
    }
    private static string Friendly(Exception error) => error is JsonException ? "A local engine returned invalid data." : error.Message;

    public void Cancel()
    {
        speech.Cancel(); editor.Cancel();
        lock (speakerLock) { try { if (speakerProcess is { HasExited: false }) speakerProcess.Kill(true); } catch (InvalidOperationException) { } }
    }
    public async ValueTask DisposeAsync()
    { Cancel(); await speech.DisposeAsync(); await editor.DisposeAsync(); models.Dispose(); }
}
