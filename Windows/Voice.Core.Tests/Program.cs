using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Text.Json;
using Voice.Core;

if (args.Length == 1 && args[0].EndsWith(".fixture", StringComparison.Ordinal))
{
    Console.WriteLine("{\"ready\":true}");
    while (Console.ReadLine() is { } line)
    {
        var value = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(line)!;
        var id = value["id"].GetString();
        var behavior = value.TryGetValue("behavior", out var item) ? item.GetString() : "echo";
        if (behavior == "hang") { await Task.Delay(Timeout.Infinite); return; }
        if (behavior == "malformed") { Console.WriteLine("not-json"); await Task.Delay(Timeout.Infinite); return; }
        if (behavior == "exit") return;
        if (behavior == "wrong-id") Console.WriteLine(JsonSerializer.Serialize(new { id = "old-generation", text = "stale" }));
        if (behavior == "large") { Console.WriteLine(new string('X', 4 * 1024 * 1024 + 100)); return; }
        if (behavior == "stderr") { await Console.Error.WriteAsync(new string('x', 32_000)); await Console.Error.FlushAsync(); }
        if (behavior == "error") Console.WriteLine(JsonSerializer.Serialize(new { id, error = "A controlled inference failure." }));
        else Console.WriteLine(JsonSerializer.Serialize(new { id, text = value.TryGetValue("text", out var text) ? text.GetString() : "ready text" }));
    }
    return;
}

var checks = await ModelStorageChecks.RunAsync();
Console.WriteLine($"Model and storage checks: {checks} passed.");
void Check(bool value, string description) { if (!value) throw new Exception(description); ++checks; }
void Reject(Action action, string description)
{
    try { action(); }
    catch (Exception e) when (e is InvalidDataException or JsonException or InvalidOperationException) { ++checks; return; }
    throw new Exception(description);
}

var names = new[] { new VocabularyEntry("Sunday dim", "Sunday Dim"), new VocabularyEntry("C S P T", "CSPT") };
Check(TextCleanup.Apply("um please tell sunday dim", names) == "Please tell Sunday Dim.", "Vocabulary and fillers should preserve proper spelling.");
Check(TextCleanup.Vocabulary("C S P T is here; sunday dimmer is not Sunday dim", names) == "CSPT is here; sunday dimmer is not Sunday Dim", "Vocabulary must match whole words.");
Check(TextCleanup.Apply("send it on Monday. Oh no, by Tuesday.", names) == "Send it on Tuesday.", "Explicit weekday correction failed.");
Check(TextCleanup.Apply("set an alarm for 2pm tomorrow. No, make it 3pm tomorrow.", names) == "Set an alarm for 3pm tomorrow.", "Natural time correction failed.");
Check(TextCleanup.Apply("set a reminder for 2pm tomorrow. No. The reminder should be for 3pm tomorrow.", names) == "Set a reminder for 3pm tomorrow.", "Natural reminder correction failed.");
Check(TextCleanup.Apply("old thought no cancel that let me restart call James", names) == "Call James.", "Explicit restart failed.");
Check(TextCleanup.ResolveExplicitCorrections("Say \"Monday, no Tuesday\" exactly") == "Say \"Monday, no Tuesday\" exactly", "Quoted correction must remain literal.");
Check(TextCleanup.FormatSpoken("open quote new line close quote") == "“new line”", "Commands in spoken quotes must remain literal.");
Check(TextCleanup.Apply("number one apples number two pears number three bananas", []) == "1. apples\n2. pears\n3. bananas.", "Explicit numbered list failed.");
Check(TextCleanup.ValidateEdited("Send 300 pounds.", "Send 200 pounds.") is null, "Editor must not invent numbers.");
Check(TextCleanup.ValidateEdited("Send the invoice.", "Do not send the invoice.") is null, "Editor must preserve negation.");
Check(TextCleanup.ValidateEdited("The weather is wonderful.", "Set an alarm tomorrow.") is null, "Editor must not substitute unrelated text.");
Check(TextCleanup.ValidateEdited("What is the capital of Spain?", "What is the capital of Spain.") is not null, "Editor punctuation should be accepted.");
Check(TextCleanup.ValidateEdited("Sure, here is your text.", "Please call James.") is null, "Editor acknowledgements must be rejected.");

var part = new AudioPart("fixture.f32", "microphone", 10, 2);
var timed = "{\"version\":1,\"text\":\" Hello there\",\"words\":[{\"text\":\" Hello\",\"start\":0.2,\"end\":0.6,\"timingValid\":true},{\"text\":\" there\",\"start\":0.6,\"end\":0.6,\"timingValid\":false}]}";
var parsed = VoiceEngine.ParseTimed(timed, part);
Check(parsed.Count == 2 && parsed[0].Start == 10.2 && !parsed[1].TimingValid, "Timed speech offset and invalid anchors must be preserved.");
Reject(() => VoiceEngine.ParseTimed(timed.Replace(" Hello there", "different text"), part), "Inconsistent timed transcript was accepted.");
Reject(() => VoiceEngine.ParseTimed(timed.Replace("\"end\":0.6", "\"end\":9"), part), "Out-of-range word timing was accepted.");
var words = new List<VoiceEngine.MeetingWord>(); var spans = new List<VoiceEngine.SpeakerSpan>();
for (var i = 0; i < 5; ++i) { words.Add(new("microphone", i * 2, i * 2 + 1, " speaker" + i, true)); spans.Add(new("microphone", i * 2, i * 2 + 1, i)); }
var assigned = VoiceEngine.AssignSpeakers(words, spans, []);
Check(assigned.Select(x => x.SpeakerLabel).Distinct().Count() == 5 && assigned[^1].SpeakerLabel == "Speaker 5", "Speaker count must not be capped at three.");
Check(VoiceEngine.AssignSpeakers([new("microphone", 0, 1, "hello", true)], [new("system", 0, 1, 0)], [])[0].SpeakerLabel == "Unclear speaker", "System speakers must not be assigned to microphone words.");
Check(VoiceEngine.AssignSpeakers([new("microphone", 0, 1, "hello", false)], [new("microphone", 0, 1, 0)], [])[0].SpeakerLabel == "Unclear speaker", "Invalid word timing must stay unassigned.");
Check(VoiceEngine.AssignSpeakers([new("microphone", 0, 1, "hello", true)], [new("microphone", 0, 1, 0), new("microphone", 0, 1, 1)], [])[0].SpeakerLabel == "Unclear speaker", "Overlapping speakers must remain uncertain.");
var record = new MeetingRecord { Title = "Meeting", Notes = "Personal notes", Summary = "Supported summary", Transcript = [new(61, 62, "Hello", "Speaker 5")], SpeakerNames = new() { ["Speaker 5"] = "James" } };
var export = VoiceEngine.ExportMeeting(record);
Check(export.Contains("Personal notes") && export.Contains("Supported summary") && export.Contains("00:01:01 · James"), "Meeting export must contain saved notes and renamed speakers.");

var temporary = Path.Combine(Path.GetTempPath(), "voice-worker-checks-" + Guid.NewGuid().ToString("N"));
Console.WriteLine("Text, timing and speaker checks passed. Starting real worker lifecycle checks…");
Directory.CreateDirectory(temporary);
try
{
    var model = Path.Combine(temporary, "model.fixture"); await File.WriteAllTextAsync(model, "fixture");
    var executable = Path.Combine(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location)!, "Voice.Core.Tests" + (OperatingSystem.IsWindows() ? ".exe" : ""));
    await using var worker = new JsonLineWorker(executable);
    var success = await worker.RequestAsync(model, new Dictionary<string, object?> { ["text"] = "A real child process reply." });
    Console.WriteLine("Worker startup and first reply passed.");
    Check(success.GetProperty("text").GetString() == "A real child process reply.", "Worker request/reply failed.");
    var wrong = await worker.RequestAsync(model, new Dictionary<string, object?> { ["behavior"] = "wrong-id", ["text"] = "current" });
    Check(wrong.GetProperty("text").GetString() == "current", "An unmatched old request ID leaked into the result.");
    _ = await worker.RequestAsync(model, new Dictionary<string, object?> { ["behavior"] = "stderr" });
    Console.WriteLine("Worker stale-ID and stderr checks passed.");
    Check(worker.Diagnostics.Length <= 16_384, "Worker diagnostics were not bounded.");
    for (var i = 0; i < 10; ++i)
    {
        using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(150));
        try { await worker.RequestAsync(model, new Dictionary<string, object?> { ["behavior"] = "hang" }, cancel.Token); throw new Exception("Cancellation returned a success."); }
        catch (OperationCanceledException) { ++checks; }
        var recovery = await worker.RequestAsync(model, new Dictionary<string, object?> { ["text"] = "restarted" });
        Check(recovery.GetProperty("text").GetString() == "restarted", "Immediate cancel/restart did not recover.");
    }
    foreach (var behavior in new[] { "malformed", "exit", "large", "error" })
    {
        try { await worker.RequestAsync(model, new Dictionary<string, object?> { ["behavior"] = behavior }); throw new Exception("Invalid engine output was accepted: " + behavior); }
        catch (Exception e) when (e is IOException or InvalidOperationException) { ++checks; }
        var recovery = await worker.RequestAsync(model, new Dictionary<string, object?> { ["text"] = "recovered" });
        Check(recovery.GetProperty("text").GetString() == "recovered", "Engine failure prevented a new request: " + behavior);
    }
    try { await worker.RequestAsync(model, new Dictionary<string, object?> { ["behavior"] = "hang" }, timeout: TimeSpan.FromMilliseconds(100)); throw new Exception("Hung worker did not time out."); }
    catch (TimeoutException) { ++checks; }
    Check((await worker.RequestAsync(model, new Dictionary<string, object?> { ["text"] = "after timeout" })).GetProperty("text").GetString() == "after timeout", "Timeout did not allow recovery.");
}
finally { Directory.Delete(temporary, true); }
Console.WriteLine($"Passed {checks} Windows core checks (including 10 real child-process cancel/restart cycles).");
