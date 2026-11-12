using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace Voice.Windows.Platform;

/// <summary>Hardware-free checks run by the packaged Windows smoke test.</summary>
public static class PlatformSelfTests
{
    public static int Run()
    {
        int passed = 0;
        void Check(bool condition, string message)
        { if (!condition) throw new InvalidOperationException("Platform check failed: " + message); passed++; }
        Check(Marshal.SizeOf<NativeMethods.Input>() == (IntPtr.Size == 8 ? 40 : 28), "Win32 INPUT union size");
        Check(PasteService.FormatForInsertion("Next sentence.", '.', null) == " Next sentence. ", "space between dictations");
        Check(PasteService.FormatForInsertion("Next sentence.", ' ', null) == "Next sentence. ", "existing separator preserved");
        Check(PasteService.FormatForInsertion("Hello", '\n', null) == "Hello ", "new paragraph");
        Check(PasteService.FormatForInsertion("Hello", '(', ')') == "Hello", "parenthesis boundaries");
        Check(PasteService.FormatForInsertion(",", 'd', ' ') == ",", "closing punctuation");
        Check(PasteService.FormatForInsertion("Hello", null, 'w') == "Hello ", "word to right");
        Check(PasteService.FormatForInsertion(" ", null, null) == "", "empty transcript");
        Check(MeetingDetector.Classify("zoom", "Zoom Meeting") == "Zoom", "native Zoom");
        Check(MeetingDetector.Classify("zoom", "Zoom Workplace") is null, "Zoom landing page");
        Check(MeetingDetector.Classify("ms-teams", "Weekly meeting | Microsoft Teams") == "Microsoft Teams", "native Teams");
        Check(MeetingDetector.Classify("chrome", "Meet - abc-defg-hij - Google Chrome") == "Google Meet", "browser Meet");
        Check(MeetingDetector.Classify("chrome", "Google Meet - Google Chrome") is null, "Meet landing page");
        Check(MeetingDetector.Classify("chrome", "Google Meet: Online Web and Video Conferencing") is null, "Meet marketing page");
        Check(MeetingDetector.Classify("chrome", "You left Google Meet - Google Chrome") is null, "ended meeting");
        Check(MeetingDetector.Classify("notepad", "Zoom Meeting") is null, "unrelated application");

        string directory = Path.Combine(Path.GetTempPath(), "Voice-platform-check-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            string audio = Path.Combine(directory, "test-microphone-00000.f32");
            File.WriteAllBytes(audio, new byte[16000 * 4]);
            string system = Path.Combine(directory, "test-system-00000.f32");
            File.WriteAllBytes(system, new byte[8000 * 4]);
            string journal = Path.Combine(directory, "test-capture.jsonl");
            string Entry(string name, string source, double time) => JsonSerializer.Serialize(new
                { action = "start", FileName = name, Source = source, StartSeconds = time, DurationSeconds = 0 });
            File.WriteAllLines(journal, new[] {
                Entry(Path.GetFileName(audio), "microphone", 0.25),
                Entry(Path.GetFileName(audio), "microphone", 0.25), // Duplicate finish/start must not duplicate audio.
                Entry(Path.GetFileName(system), "system", 2.5),
                Entry("../outside.f32", "system", 0),
                Entry(Path.GetFileName(audio), "unknown", 0),
                Entry(Path.GetFileName(audio), "microphone", -1),
                "{\"action\":\"start\"," // Simulate an interrupted final journal write.
            });
            var recovered = AudioRecorder.RecoverParts(directory);
            Check(recovered.Count == 2, "recovery rejects traversal/invalid metadata and duplicates");
            Check(recovered[0].Source == "microphone" && recovered[0].StartSeconds == 0.25 && recovered[0].DurationSeconds == 1,
                "recover partial microphone by actual file length");
            Check(recovered[1].Source == "system" && recovered[1].StartSeconds == 2.5 && recovered[1].DurationSeconds == 0.5,
                "preserve system audio gap and source");
            File.WriteAllBytes(audio, new byte[3]);
            Check(AudioRecorder.RecoverParts(directory).All(x => x.Path != audio), "reject incomplete float samples");
            Check(AudioRecorder.RecoverParts(Path.Combine(directory, "absent")).Count == 0, "absent capture folder");
        }
        finally { Directory.Delete(directory, true); }
        return passed;
    }
}
