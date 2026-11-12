using Voice.Core;

namespace Voice.Windows.ViewModels;

public sealed class MeetingItem(MeetingRecord record) : Bindable
{
    public MeetingRecord Record { get; } = record;
    public string Title { get => Record.Title; set { Record.Title = value; Changed(); } }
    public string Notes { get => Record.Notes; set { Record.Notes = value; Changed(); } }
    public string Summary { get => Record.Summary; set { Record.Summary = value; Changed(); } }
    public string DateText => Record.CreatedAt.LocalDateTime.ToString("d MMM yyyy · HH:mm");
    public string DurationText => $"{Math.Ceiling(Record.AudioParts.Select(p => p.StartSeconds + p.DurationSeconds).DefaultIfEmpty(0).Max() / 60):0} min";
    public string Status => Record.Status;
    public string Error => Record.Error ?? "";
    public string Transcript => string.Join("\n\n", Record.Transcript.Select(s =>
        $"[{TimeSpan.FromSeconds(Math.Max(0,s.StartSeconds)):hh\\:mm\\:ss} · {Record.SpeakerNames.GetValueOrDefault(s.SpeakerLabel, s.SpeakerLabel)}]\n{s.Text}"));
    public string ExportText => $"{Title}\n{DateText}\n\nMY NOTES\n{Notes}\n\nSUMMARY\n{Summary}\n\nTRANSCRIPT\n{Transcript}";
    public void Refresh() { foreach (var p in new[] {nameof(Title),nameof(Notes),nameof(Summary),nameof(Transcript),nameof(DurationText),nameof(Status),nameof(Error)}) Changed(p); }
}

public sealed record HistoryItem(HistoryEntry Record)
{
    public string Text => Record.Text;
    public string DateText => Record.CreatedAt.LocalDateTime.ToString("d MMM · HH:mm") + " · " + Record.Mode;
}
