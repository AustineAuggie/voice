using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
using System.Text.Json;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Voice.Windows.Platform;

public sealed record CapturedAudioPart(string Path, string Source, double StartSeconds, double DurationSeconds);

/// <summary>
/// Captures microphone and, when requested, the default playback endpoint. Each source uses
/// the same QPC origin, preserving pauses in loopback audio. Native 30-second float32 files
/// are flushed while recording; memory use does not grow with meeting length.
/// </summary>
public sealed class AudioRecorder : IAsyncDisposable
{
    private readonly SemaphoreSlim lifecycle = new(1, 1);
    private CaptureSession? session;
    private IReadOnlyList<CapturedAudioPart> lastParts = Array.Empty<CapturedAudioPart>();
    public bool IsRecording => session is { } current && !current.Stop.IsCancellationRequested;
    public IReadOnlyList<CapturedAudioPart> CompletedParts => session?.Parts() ?? lastParts;
    public event Action<Exception>? Error;
    public event Action<float, float>? LevelChanged;
    public event Action<CapturedAudioPart>? PartCompleted;

    /// <summary>Recover flushed segments, including a partially written last segment after a crash.</summary>
    public static IReadOnlyList<CapturedAudioPart> RecoverParts(string directory)
    {
        var root = Path.GetFullPath(directory);
        if (!Directory.Exists(root)) return Array.Empty<CapturedAudioPart>();
        var found = new Dictionary<string, CapturedAudioPart>(StringComparer.OrdinalIgnoreCase);
        foreach (var journal in Directory.EnumerateFiles(root, "*-capture.jsonl"))
        {
            foreach (var line in File.ReadLines(journal))
            {
                try
                {
                    using var json = JsonDocument.Parse(line);
                    var value = json.RootElement;
                    string? name = value.GetProperty("FileName").GetString();
                    string? source = value.GetProperty("Source").GetString();
                    double start = value.GetProperty("StartSeconds").GetDouble();
                    if (string.IsNullOrWhiteSpace(name) || Path.GetFileName(name) != name ||
                        source is not ("microphone" or "system") || !double.IsFinite(start) || start < 0) continue;
                    string path = Path.Combine(root, name);
                    if (!File.Exists(path)) continue;
                    long length = new FileInfo(path).Length;
                    if (length < 4 || length % 4 != 0) continue;
                    found[path] = new CapturedAudioPart(path, source, start, length / 64000.0);
                }
                catch (JsonException) { /* A crash can leave the final journal line incomplete. */ }
                catch (KeyNotFoundException) { }
                catch (InvalidOperationException) { }
                catch (IOException) { }
            }
        }
        return found.Values.OrderBy(x => x.StartSeconds).ToArray();
    }

    public async Task StartAsync(string directory, bool includeSystemAudio, CancellationToken cancellationToken = default)
    {
        await lifecycle.WaitAsync(cancellationToken);
        try
        {
            if (session is not null) throw new InvalidOperationException("Audio capture is still running or stopping.");
            cancellationToken.ThrowIfCancellationRequested();
            Directory.CreateDirectory(directory);
            var current = new CaptureSession(Path.GetFullPath(directory), includeSystemAudio, cancellationToken,
                (mic, system) => LevelChanged?.Invoke(mic, system), error => Error?.Invoke(error),
                part => PartCompleted?.Invoke(part));
            session = current;
            lastParts = Array.Empty<CapturedAudioPart>();
            try { await current.StartAsync(); }
            catch
            {
                current.Stop.Cancel();
                await current.FinishAsync();
                session = null;
                current.Dispose();
                throw;
            }
        }
        finally { lifecycle.Release(); }
    }

    public async Task<IReadOnlyList<CapturedAudioPart>> StopAsync()
    {
        await lifecycle.WaitAsync();
        try
        {
            if (session is null) return lastParts;
            var current = session;
            current.Stop.Cancel();
            try
            {
                await current.FinishAsync();
                lastParts = current.Parts();
                if (current.Failure is { } failure)
                    throw new IOException("Audio capture stopped unexpectedly. Saved audio has been kept. " + failure.Message, failure);
                return lastParts;
            }
            finally { session = null; current.Dispose(); }
        }
        finally { lifecycle.Release(); }
    }

    public async Task CancelAsync()
    {
        await lifecycle.WaitAsync();
        try
        {
            if (session is null) return;
            var current = session;
            current.Stop.Cancel();
            try
            {
                await current.FinishAsync();
                // Only this recording's generated files are removed on an explicit cancel.
                foreach (var path in current.CreatedFiles())
                    try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
                lastParts = Array.Empty<CapturedAudioPart>();
            }
            finally { session = null; current.Dispose(); }
        }
        finally { lifecycle.Release(); }
    }

    public async ValueTask DisposeAsync()
    {
        // Preserve partial meeting audio when the app closes; CancelAsync is an explicit discard.
        try { await StopAsync(); } catch { }
        lifecycle.Dispose();
    }

    private sealed class CaptureSession : IDisposable
    {
        internal readonly CancellationTokenSource Stop;
        private readonly string directory;
        private readonly string id = Guid.NewGuid().ToString("N");
        private readonly bool systemAudio;
        private readonly double qpcOrigin = Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
        private readonly Action<float, float> onLevel;
        private readonly Action<Exception> onError;
        private readonly Action<CapturedAudioPart> onPart;
        private readonly List<CapturedAudioPart> parts = new();
        private readonly List<string> files = new();
        private readonly object gate = new();
        private readonly List<Task> workers = new();
        private float micLevel, systemLevel;
        private double lastLevel;
        internal Exception? Failure { get; private set; }

        internal CaptureSession(string directory, bool systemAudio, CancellationToken token,
            Action<float, float> onLevel, Action<Exception> onError, Action<CapturedAudioPart> onPart)
        {
            this.directory = directory; this.systemAudio = systemAudio;
            this.onLevel = onLevel; this.onError = onError; this.onPart = onPart;
            Stop = CancellationTokenSource.CreateLinkedTokenSource(token);
        }

        internal async Task StartAsync()
        {
            var ready = new List<Task> { StartSource(false) };
            if (systemAudio) ready.Add(StartSource(true));
            await Task.WhenAll(ready);
            Stop.Token.ThrowIfCancellationRequested();
        }

        private Task StartSource(bool loopback)
        {
            var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            workers.Add(done.Task);
            var thread = new Thread(() => Capture(loopback, ready, done))
            { IsBackground = true, Name = loopback ? "Voice system audio" : "Voice microphone" };
            thread.SetApartmentState(ApartmentState.MTA);
            thread.Start();
            return ready.Task;
        }

        private void Capture(bool loopback, TaskCompletionSource ready, TaskCompletionSource done)
        {
            MMDeviceEnumerator? devices = null;
            MMDevice? device = null;
            AudioClient? client = null;
            SegmentWriter? writer = null;
            bool started = false;
            var source = loopback ? "system" : "microphone";
            try
            {
                Stop.Token.ThrowIfCancellationRequested();
                devices = new MMDeviceEnumerator();
                device = devices.GetDefaultAudioEndpoint(loopback ? DataFlow.Render : DataFlow.Capture,
                    loopback ? Role.Multimedia : Role.Communications);
                client = device.AudioClient;
                var format = WaveFormat.CreateIeeeFloatWaveFormat(16000, 1);
                var flags = AudioClientStreamFlags.AutoConvertPcm | AudioClientStreamFlags.SrcDefaultQuality;
                if (loopback) flags |= AudioClientStreamFlags.Loopback;
                client.Initialize(AudioClientShareMode.Shared, flags, 1_000_000, 0, format, Guid.Empty);
                var capture = client.AudioCaptureClient;
                writer = new SegmentWriter(this, source);
                client.Start(); started = true;
                ready.TrySetResult();
                var buffer = new byte[Math.Max(16000, client.BufferSize * 4)];
                while (!Stop.IsCancellationRequested)
                {
                    ReadAvailable(capture, writer, source, ref buffer);
                    if (Elapsed > 6 * 60 * 60) throw new IOException("The six-hour recording limit has been reached. Start a new recording.");
                    Stop.Token.WaitHandle.WaitOne(10);
                }
                // Stop producing before draining the final buffered audio.
                client.Stop(); started = false;
                ReadAvailable(capture, writer, source, ref buffer);
            }
            catch (OperationCanceledException) when (Stop.IsCancellationRequested) { ready.TrySetCanceled(); }
            catch (Exception error)
            {
                ready.TrySetException(new IOException(loopback
                    ? "Windows playback audio could not be captured. Check the default playback device. " + error.Message
                    : "The microphone could not be captured. Check Windows Settings → Privacy & security → Microphone and the default microphone. " + error.Message, error));
                Fail(error);
            }
            finally
            {
                // Device removal can make Stop throw. Never let teardown terminate the process.
                if (started) try { client?.Stop(); } catch (Exception error) { Fail(error); }
                try { writer?.Dispose(); } catch (Exception error) { Fail(error); }
                try { client?.Dispose(); } catch { }
                try { device?.Dispose(); } catch { }
                try { devices?.Dispose(); } catch { }
                ready.TrySetCanceled();
                done.TrySetResult();
            }
        }

        private void ReadAvailable(AudioCaptureClient capture, SegmentWriter writer, string source, ref byte[] buffer)
        {
            // A stopped endpoint has finite buffered packets. Cap each pass so cancellation wins.
            for (int packets = 0; packets < 200 && capture.GetNextPacketSize() > 0; packets++)
            {
                nint data = capture.GetBuffer(out int frames, out var flags, out _, out long qpc);
                if (frames == 0) break;
                try
                {
                    int count = checked(frames * 4);
                    if (buffer.Length < count) buffer = new byte[count];
                    if ((flags & AudioClientBufferFlags.Silent) != 0) Array.Clear(buffer, 0, count);
                    else Marshal.Copy(data, buffer, 0, count);
                    var samples = MemoryMarshal.Cast<byte, float>(buffer.AsSpan(0, count));
                    float peak = 0;
                    foreach (ref float sample in samples)
                    {
                        if (!float.IsFinite(sample)) sample = 0;
                        sample = Math.Clamp(sample, -1f, 1f);
                        peak = Math.Max(peak, Math.Abs(sample));
                    }
                    double timestamp = qpc / 10_000_000.0 - qpcOrigin;
                    if ((flags & AudioClientBufferFlags.TimestampError) != 0 || timestamp < -1 || timestamp > Elapsed + 1)
                        timestamp = Math.Max(0, Elapsed - frames / 16000.0);
                    timestamp = Math.Max(0, timestamp);
                    // Copy out of the endpoint before doing any disk I/O.
                    capture.ReleaseBuffer(frames); frames = 0;
                    writer.Write(buffer.AsSpan(0, count), timestamp);
                    ReportLevel(source, peak);
                }
                finally { if (frames > 0) capture.ReleaseBuffer(frames); }
            }
        }

        private double Elapsed => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency - qpcOrigin;
        private void ReportLevel(string source, float peak)
        {
            float mic, system;
            lock (gate)
            {
                if (source == "microphone") micLevel = peak; else systemLevel = peak;
                if (Elapsed - lastLevel < 0.05) return;
                lastLevel = Elapsed; mic = micLevel; system = systemLevel;
            }
            try { onLevel(mic, system); } catch { /* A UI subscriber must not interrupt capture. */ }
        }

        private void Fail(Exception error)
        {
            bool first;
            lock (gate) { first = Failure is null; Failure ??= error; }
            Stop.Cancel();
            if (first) try { onError(error); } catch { }
        }

        internal Task FinishAsync() => Task.WhenAll(workers);
        internal IReadOnlyList<CapturedAudioPart> Parts() { lock (gate) return parts.OrderBy(x => x.StartSeconds).ToArray(); }
        internal string[] CreatedFiles() { lock (gate) return files.ToArray(); }
        public void Dispose() => Stop.Dispose();

        private sealed class SegmentWriter : IDisposable
        {
            private const int SamplesPerPart = 30 * 16000;
            private readonly CaptureSession session;
            private readonly string source;
            private FileStream? output;
            private string? path;
            private long samples;
            private double start, lastFlush;
            private int sequence;
            internal SegmentWriter(CaptureSession session, string source) { this.session = session; this.source = source; }

            internal void Write(ReadOnlySpan<byte> bytes, double timestamp)
            {
                if (output is not null && Math.Abs(timestamp - (start + samples / 16000.0)) > 0.1)
                    Close(); // Gap or clock discontinuity: preserve its time instead of concatenating it away.
                while (!bytes.IsEmpty)
                {
                    if (output is null) Open(timestamp);
                    int count = Math.Min(bytes.Length, checked((int)(SamplesPerPart - samples)) * 4);
                    output!.Write(bytes[..count]);
                    samples += count / 4;
                    bytes = bytes[count..]; timestamp += count / 64000.0;
                    if (samples >= SamplesPerPart) Close();
                    else if (session.Elapsed - lastFlush >= 1)
                    { output.Flush(true); lastFlush = session.Elapsed; }
                }
            }

            private void Open(double timestamp)
            {
                start = timestamp; samples = 0;
                path = Path.Combine(session.directory, $"{session.id}-{source}-{sequence++:D5}.f32");
                output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 65536);
                lock (session.gate) session.files.Add(path);
                Journal("start", new CapturedAudioPart(path, source, start, 0));
            }

            private void Close()
            {
                if (output is null) return;
                var stream = output; output = null;
                try { stream.Flush(true); } finally { stream.Dispose(); }
                var part = new CapturedAudioPart(path!, source, start, samples / 16000.0);
                if (samples > 0)
                {
                    lock (session.gate) session.parts.Add(part);
                    Journal("finish", part);
                    try { session.onPart(part); } catch { /* Capture journal still retains the segment for recovery. */ }
                }
            }

            private void Journal(string action, CapturedAudioPart part)
            {
                var journal = Path.Combine(session.directory, $"{session.id}-capture.jsonl");
                lock (session.gate)
                {
                    if (!session.files.Contains(journal)) session.files.Add(journal);
                    using var stream = new FileStream(journal, FileMode.Append, FileAccess.Write, FileShare.Read);
                    using var writer = new StreamWriter(stream, leaveOpen: true);
                    writer.WriteLine(JsonSerializer.Serialize(new { action, part.Source, part.StartSeconds,
                        part.DurationSeconds, FileName = Path.GetFileName(part.Path) }));
                    writer.Flush(); stream.Flush(true);
                }
            }

            public void Dispose() => Close();
        }
    }
}
