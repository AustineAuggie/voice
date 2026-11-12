using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text;
using System.Windows.Threading;

namespace Voice.Windows.Platform;

public sealed record MeetingSuggestion(string Key, string AppName, string Title);

/// <summary>Checks visible window titles only. It never opens or records a microphone.</summary>
public sealed class MeetingDetector : IDisposable
{
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(2) };
    private readonly Dictionary<string, Candidate> candidates = new();
    private bool busy;
    private bool enabled = true;
    public event Action<MeetingSuggestion>? Suggested;
    public bool Enabled { get => enabled; set { enabled = value; if (!value) candidates.Clear(); } }

    public MeetingDetector() => timer.Tick += Tick;
    public void Start() => timer.Start();
    public void SetBusy(bool value) => busy = value;
    public void Dismiss(string key) { if (candidates.TryGetValue(key, out var value)) value.Prompted = true; }
    public void Dispose() { timer.Stop(); timer.Tick -= Tick; candidates.Clear(); }

    private void Tick(object? sender, EventArgs e)
    {
        if (!enabled) return;
        var now = DateTimeOffset.UtcNow;
        var detected = FindCandidates();
        var keys = detected.Select(x => x.Key).ToHashSet(StringComparer.Ordinal);
        foreach (var key in candidates.Keys.ToArray())
            if (!keys.Contains(key) && now - candidates[key].LastSeen > TimeSpan.FromSeconds(12)) candidates.Remove(key);
        foreach (var suggestion in detected)
        {
            if (!candidates.TryGetValue(suggestion.Key, out var candidate))
                candidates[suggestion.Key] = candidate = new Candidate(now);
            candidate.LastSeen = now;
            if (busy || candidate.Prompted || now - candidate.FirstSeen < TimeSpan.FromSeconds(6)) continue;
            candidate.Prompted = true;
            Suggested?.Invoke(suggestion);
            break; // One prompt at a time; the app decides when it is dismissed.
        }
    }

    private static List<MeetingSuggestion> FindCandidates()
    {
        var result = new List<MeetingSuggestion>();
        nint foreground = NativeMethods.GetForegroundWindow();
        NativeMethods.EnumWindows((handle, _) =>
        {
            try
            {
                if (!NativeMethods.IsWindowVisible(handle)) return true;
                NativeMethods.GetWindowThreadProcessId(handle, out uint pid);
                if (pid == Environment.ProcessId) return true;
                var text = new StringBuilder(512);
                NativeMethods.GetWindowText(handle, text, text.Capacity);
                string title = text.ToString();
                using var process = Process.GetProcessById((int)pid);
                var app = Classify(process.ProcessName, title);
                if (app is null) return true;
                // Include window handle and title so leaving and joining a different meeting re-arms.
                var item = new MeetingSuggestion($"{pid}:{handle}:{title}", app, title);
                if (handle == foreground) result.Insert(0, item); else result.Add(item);
            }
            catch { /* Windows can disappear or belong to a protected process. */ }
            return true;
        }, 0);
        return result;
    }

    public static string? Classify(string processName, string windowTitle)
    {
        string process = processName.ToLowerInvariant();
        string title = windowTitle.Trim().ToLowerInvariant();
        if (title.Length == 0 || new[] { "meeting ended", "call ended", "you left", "you've left", "you have left", "join a meeting", "sign in" }.Any(title.Contains)) return null;
        var titleWithoutBrowser = title;
        foreach (var suffix in new[] { " - google chrome", " - microsoft edge", " — mozilla firefox", " - brave", " - opera", " - vivaldi" })
            if (titleWithoutBrowser.EndsWith(suffix, StringComparison.Ordinal)) titleWithoutBrowser = titleWithoutBrowser[..^suffix.Length];
        if (titleWithoutBrowser is "google meet" or "meet" or "microsoft teams" or "zoom" or "zoom workplace") return null;
        if (title.StartsWith("google meet:", StringComparison.Ordinal)) return null;
        if (process == "zoom" && (title.Contains("zoom meeting") || title.Contains("zoom webinar"))) return "Zoom";
        if (process is "ms-teams" or "teams" && (title.Contains("meeting") || title.Contains("call with") || title.Contains("meeting in"))) return "Microsoft Teams";
        bool browser = process is "chrome" or "msedge" or "firefox" or "brave" or "opera" or "vivaldi";
        if (!browser) return null;
        if (title.Contains("google meet") || title.StartsWith("meet - ") || title.StartsWith("meet – ")) return "Google Meet";
        if (title.Contains("zoom meeting") || title.Contains("zoom webinar")) return "Zoom";
        if (title.Contains("microsoft teams") && (title.Contains("meeting") || title.Contains("call"))) return "Microsoft Teams";
        return null;
    }

    private sealed class Candidate(DateTimeOffset now)
    {
        internal DateTimeOffset FirstSeen = now, LastSeen = now;
        internal bool Prompted;
    }
}
