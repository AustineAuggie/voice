using System.Text.Json;

namespace Voice.Core;

public sealed class AppPaths
{
    public string Root { get; }
    public string Models => System.IO.Path.Combine(Root, "Models");
    public string Meetings => System.IO.Path.Combine(Root, "Meetings");
    public string Sessions => System.IO.Path.Combine(Root, "Sessions");
    public AppPaths(string? root = null)
    {
        Root = System.IO.Path.GetFullPath(root ?? System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Voice"));
        foreach (var path in new[] { Root, Models, Meetings, Sessions }) EnsurePrivateDirectory(path);
    }
    public string ModelPath(string filename)
    {
        var path = System.IO.Path.GetFullPath(System.IO.Path.Combine(Models, filename));
        if (!path.StartsWith(Models + System.IO.Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Model paths must stay inside Voice's model directory.", nameof(filename));
        return path;
    }
    public string MeetingDirectory(Guid id) => System.IO.Path.Combine(Meetings, id.ToString("D"));
    public string NewSessionDirectory()
    {
        var path = System.IO.Path.Combine(Sessions, Guid.NewGuid().ToString("D"));
        EnsurePrivateDirectory(path);
        return path;
    }
    internal static void EnsurePrivateDirectory(string path)
    {
        Directory.CreateDirectory(path);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    }
    internal static void MakePrivate(string path)
    {
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
    }
}

public sealed class LocalStore
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };
    private readonly object gate = new();
    public AppPaths Paths { get; }
    public LocalStore(AppPaths paths) => Paths = paths;

    public VoiceSettings LoadSettings() => Read(System.IO.Path.Combine(Paths.Root, "settings.json"), () => new VoiceSettings());
    public void SaveSettings(VoiceSettings value) => Write(System.IO.Path.Combine(Paths.Root, "settings.json"), value);
    public List<VocabularyEntry> LoadVocabulary() => Read(System.IO.Path.Combine(Paths.Root, "vocabulary.json"), () => new List<VocabularyEntry>());
    public void SaveVocabulary(IEnumerable<VocabularyEntry> value) => Write(System.IO.Path.Combine(Paths.Root, "vocabulary.json"), value.ToList());
    public List<HistoryEntry> LoadHistory() => Read(System.IO.Path.Combine(Paths.Root, "history.json"), () => new List<HistoryEntry>());
    public void SaveHistory(IEnumerable<HistoryEntry> value) => Write(System.IO.Path.Combine(Paths.Root, "history.json"), value.Take(500).ToList());

    public List<MeetingRecord> LoadMeetings()
    {
        lock (gate)
        {
            var result = new List<MeetingRecord>();
            foreach (var path in Directory.EnumerateDirectories(Paths.Meetings))
                if (Guid.TryParse(System.IO.Path.GetFileName(path), out var id) && File.Exists(System.IO.Path.Combine(path, "meeting.json")))
                    result.Add(LoadMeeting(id));
            return result.OrderByDescending(m => m.CreatedAt).ToList();
        }
    }
    public MeetingRecord LoadMeeting(Guid id)
    {
        var path = System.IO.Path.Combine(Paths.MeetingDirectory(id), "meeting.json");
        if (!File.Exists(path)) throw new FileNotFoundException("The saved meeting could not be found.", path);
        var meeting = Read(path, () => new MeetingRecord { Id = id });
        if (meeting.Id != id || meeting.Transcript == null || meeting.AudioParts == null || meeting.SpeakerNames == null)
            throw new InvalidDataException($"The saved meeting is invalid and has been retained: {path}");
        return meeting;
    }
    public void SaveMeeting(MeetingRecord value)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (value.Id == Guid.Empty) throw new ArgumentException("Meetings must have a unique identifier.");
        Write(System.IO.Path.Combine(Paths.MeetingDirectory(value.Id), "meeting.json"), value);
    }

    // Never turn a corrupt document into an empty default and then overwrite it.
    private T Read<T>(string path, Func<T> fallback)
    {
        lock (gate)
        {
            if (!File.Exists(path)) return fallback();
            try
            {
                if (new FileInfo(path).Length > 64 * 1024 * 1024) throw new InvalidDataException("Document exceeds the supported size.");
                using var stream = File.OpenRead(path);
                return JsonSerializer.Deserialize<T>(stream, JsonOptions) ?? throw new JsonException("Document is empty.");
            }
            catch (Exception error) when (error is JsonException or NotSupportedException)
            {
                throw new InvalidDataException($"Voice could not read {System.IO.Path.GetFileName(path)}. The original file has been retained. Location: {path}", error);
            }
        }
    }
    private void Write<T>(string path, T value)
    {
        lock (gate)
        {
            if (File.Exists(path)) _ = Read(path, () => value);
            AppPaths.EnsurePrivateDirectory(System.IO.Path.GetDirectoryName(path)!);
            var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    AppPaths.MakePrivate(temporary);
                    JsonSerializer.Serialize(stream, value, JsonOptions);
                    stream.Flush(flushToDisk: true);
                }
                if (File.Exists(path)) File.Replace(temporary, path, path + ".bak", ignoreMetadataErrors: false);
                else File.Move(temporary, path);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
    }
}
