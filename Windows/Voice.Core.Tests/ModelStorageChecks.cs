using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Formats.Tar;
using Voice.Core;

public static class ModelStorageChecks
{
    public static async Task<int> RunAsync()
    {
        var temporary = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "voice-model-checks-" + Guid.NewGuid().ToString("N"));
        var checks = 0;
        void Check(bool value, string description) { if (!value) throw new Exception(description); ++checks; }
        try
        {
            var paths = new AppPaths(temporary);
            var store = new LocalStore(paths);
            Check(!store.LoadSettings().CleanMode, "First launch must use Fast mode.");
            store.SaveSettings(new VoiceSettings { Language = "en" });
            store.SaveSettings(new VoiceSettings { Language = "fr" });
            Check(store.LoadSettings().Language == "fr", "Atomic settings replacement failed.");
            Check(File.Exists(System.IO.Path.Combine(paths.Root, "settings.json.bak")), "Replacing settings must retain a backup.");
            var vocabulary = new[] { new VocabularyEntry("Sunday dim", "Sunday Dim") };
            store.SaveVocabulary(vocabulary);
            Check(store.LoadVocabulary().SequenceEqual(vocabulary), "Vocabulary did not round trip.");
            var meeting = new MeetingRecord { Title = "A local meeting", Notes = "Original notes", Transcript = [new(0, 1, "Hello", "Speaker 1")] };
            store.SaveMeeting(meeting);
            Check(store.LoadMeeting(meeting.Id).Notes == "Original notes" && store.LoadMeetings().Count == 1, "Meeting did not round trip.");
            var corruptedPath = System.IO.Path.Combine(paths.Root, "settings.json");
            File.WriteAllText(corruptedPath, "{broken");
            try { _ = store.LoadSettings(); throw new Exception("Corrupt settings must not load as defaults."); }
            catch (InvalidDataException) { ++checks; }
            try { store.SaveSettings(new VoiceSettings()); throw new Exception("Corrupt settings must not be overwritten."); }
            catch (InvalidDataException) { ++checks; }
            Check(File.ReadAllText(corruptedPath) == "{broken", "Corrupt settings changed unexpectedly.");
            try { paths.ModelPath("../../outside.bin"); throw new Exception("Model traversal was accepted."); }
            catch (ArgumentException) { ++checks; }

            var data = Encoding.UTF8.GetBytes("verified local speech model fixture");
            var digest = Convert.ToHexString(SHA256.HashData(data));
            var asset = new ModelAsset("fixture", "fixture.bin", "https://example.invalid/fixture.bin", digest, data.Length);
            var requests = 0;
            using var http = new HttpClient(new FakeHandler((request, token) =>
            {
                ++requests;
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { RequestMessage = request, Content = new ByteArrayContent(data) });
            }));
            using var manager = new ModelManager(paths, http);
            var target = await manager.EnsureAsync(asset);
            Check(File.ReadAllBytes(target).SequenceEqual(data), "Verified model bytes were not saved.");
            Check(await manager.VerifyAsync(asset), "Verified model failed its checksum.");
            _ = await manager.EnsureAsync(asset);
            Check(requests == 1, "A verified existing model was downloaded again.");

            File.WriteAllText(target, "old invalid file must remain on download failure");
            var before = File.ReadAllBytes(target);
            try { await manager.EnsureAsync(asset with { Sha256 = new string('0', 64) }); throw new Exception("Bad checksum was accepted."); }
            catch (InvalidDataException) { ++checks; }
            Check(File.ReadAllBytes(target).SequenceEqual(before), "Failed download replaced the previous model.");
            Check(!Directory.EnumerateFiles(paths.Models, "*.download", SearchOption.AllDirectories).Any(), "Failed download left a temporary file.");
            try { await manager.EnsureAsync(asset with { Bytes = data.Length + 1 }); throw new Exception("Wrong model size was accepted."); }
            catch (InvalidDataException) { ++checks; }
            try { await manager.EnsureAsync(asset with { Url = "http://example.invalid/model" }); throw new Exception("Non-HTTPS model URL was accepted."); }
            catch (InvalidDataException) { ++checks; }
            try { await manager.EnsureAsync(asset with { Filename = "../../outside.bin" }); throw new Exception("Download path traversal was accepted."); }
            catch (ArgumentException) { ++checks; }
            using (var gateTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(5)))
            {
                await manager.EnsureAsync(asset, cancellationToken: gateTimeout.Token);
                Check(await manager.VerifyAsync(asset), "An invalid path permanently locked model downloads.");
            }

            using var tarBytes = new MemoryStream();
            using (var writer = new TarWriter(tarBytes, TarEntryFormat.Pax, leaveOpen: true))
            {
                writer.WriteEntry(new PaxTarEntry(TarEntryType.RegularFile, "models/model.onnx") { DataStream = new MemoryStream(data) });
                writer.WriteEntry(new PaxTarEntry(TarEntryType.RegularFile, "unused.txt") { DataStream = new MemoryStream(Encoding.UTF8.GetBytes("Do not extract this.")) });
            }
            var archiveData = tarBytes.ToArray();
            using var archiveHttp = new HttpClient(new FakeHandler((request, token) => Task.FromResult(
                new HttpResponseMessage(HttpStatusCode.OK) { RequestMessage = request, Content = new ByteArrayContent(archiveData) })));
            using var archiveManager = new ModelManager(paths, archiveHttp);
            var archiveAsset = new ModelAsset("archive-fixture", "Speakers/test.onnx", "https://example.invalid/archive.tar", Convert.ToHexString(SHA256.HashData(archiveData)), null, "models/model.onnx", digest, 1_000_000);
            var extractedPath = await archiveManager.EnsureAsync(archiveAsset);
            Check(File.ReadAllBytes(extractedPath).SequenceEqual(data), "Verified archive member was not extracted correctly.");
            Check(!Directory.EnumerateFiles(paths.Root, "unused.txt", SearchOption.AllDirectories).Any(), "Unrequested archive member was extracted.");
            try { await archiveManager.EnsureAsync(archiveAsset with { ExtractedSha256 = new string('0', 64) }); throw new Exception("Bad extracted checksum was accepted."); }
            catch (InvalidDataException) { ++checks; }
            Check(File.ReadAllBytes(extractedPath).SequenceEqual(data), "Failed extracted checksum replaced a previous model.");

            using var cancellation = new CancellationTokenSource();
            using var cancelHttp = new HttpClient(new FakeHandler((request, token) => Task.FromResult(
                new HttpResponseMessage(HttpStatusCode.OK) { RequestMessage = request, Content = new StreamContent(new CancellingStream(cancellation)) })));
            using var cancelManager = new ModelManager(paths, cancelHttp);
            try { await cancelManager.EnsureAsync(asset with { Filename = "cancelled.bin", Bytes = null }, cancellationToken: cancellation.Token); throw new Exception("Cancelled download completed."); }
            catch (OperationCanceledException) { ++checks; }
            Check(!File.Exists(paths.ModelPath("cancelled.bin")), "Cancelled download installed a model.");
            Check(!Directory.EnumerateFiles(paths.Models, "*.download", SearchOption.AllDirectories).Any(), "Cancelled download left temporary files.");
            return checks;
        }
        finally { Directory.Delete(temporary, recursive: true); }
    }
    private sealed class FakeHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> handler) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => handler(request, cancellationToken);
    }
    private sealed class CancellingStream(CancellationTokenSource cancellation) : Stream
    {
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => 0; set => throw new NotSupportedException(); }
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            cancellation.Cancel();
            return ValueTask.FromCanceled<int>(cancellationToken);
        }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
