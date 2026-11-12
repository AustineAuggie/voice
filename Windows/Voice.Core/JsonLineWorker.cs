using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;

namespace Voice.Core;

/// <summary>A single local model process. A cancelled request tears down its generation;
/// an old reply can never complete a request from the next process.</summary>
public sealed class JsonLineWorker : IAsyncDisposable
{
    private readonly string executable;
    private readonly SemaphoreSlim serial = new(1, 1);
    private readonly object sync = new();
    private Process? process;
    private CancellationTokenSource? processCancellation;
    private TaskCompletionSource<bool>? ready;
    private TaskCompletionSource<JsonElement>? response;
    private string? requestId;
    private string? loadedModel;
    private long generation;
    private string diagnostics = "";
    private bool disposed;
    public string Diagnostics { get { lock (sync) return diagnostics; } }

    public JsonLineWorker(string executablePath) => executable = executablePath;

    public async Task WarmAsync(string model, CancellationToken cancellationToken = default)
    {
        await serial.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { await StartAsync(model, cancellationToken).ConfigureAwait(false); }
        finally { serial.Release(); }
    }

    public async Task<JsonElement> RequestAsync(string model, IReadOnlyDictionary<string, object?> fields,
        CancellationToken cancellationToken = default, TimeSpan? timeout = null)
    {
        await serial.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await StartAsync(model, cancellationToken).ConfigureAwait(false);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            deadline.CancelAfter(timeout ?? TimeSpan.FromMinutes(20));
            var id = Guid.NewGuid().ToString("N");
            var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
            Process child;
            long current;
            lock (sync)
            {
                child = process ?? throw new IOException("The local engine stopped.");
                current = generation; requestId = id; response = completion;
            }
            using var registration = deadline.Token.Register(() => StopGeneration(current,
                new OperationCanceledException("Local processing cancelled.", deadline.Token)));
            var payload = new Dictionary<string, object?>(fields) { ["id"] = id };
            try
            {
                await child.StandardInput.WriteLineAsync(JsonSerializer.Serialize(payload).AsMemory(), deadline.Token).ConfigureAwait(false);
                await child.StandardInput.FlushAsync(deadline.Token).ConfigureAwait(false);
                var result = await completion.Task.WaitAsync(deadline.Token).ConfigureAwait(false);
                if (result.TryGetProperty("error", out var error))
                    throw new InvalidOperationException(error.GetString() ?? "Local processing failed.");
                return result;
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                var failure = new TimeoutException("Local processing timed out. The original recording is retained.");
                StopGeneration(current, failure);
                throw failure;
            }
            catch
            {
                StopGeneration(current, new IOException("The local engine request stopped."));
                throw;
            }
            finally
            {
                lock (sync) if (generation == current && requestId == id) { requestId = null; response = null; }
            }
        }
        finally { serial.Release(); }
    }

    private async Task StartAsync(string model, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        lock (sync) if (process is { HasExited: false } && loadedModel == model && ready?.Task.IsCompletedSuccessfully == true) return;
        StopGeneration(null, new IOException("Local engine restarted."));
        if (!File.Exists(executable)) throw new FileNotFoundException("A local engine is missing. Reinstall the complete Voice Windows folder.", executable);
        if (!File.Exists(model)) throw new FileNotFoundException("Download the selected model in Settings first.", model);
        var child = new Process { StartInfo = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8, WorkingDirectory = Path.GetDirectoryName(executable)!
        } };
        child.StartInfo.ArgumentList.Add(model);
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var stop = new CancellationTokenSource();
        long current;
        lock (sync)
        {
            current = ++generation; process = child; processCancellation = stop;
            ready = completion; loadedModel = model; diagnostics = "";
        }
        try
        {
            if (!child.Start()) throw new IOException("Could not start the local engine.");
            _ = ReadOutputAsync(child, current, stop.Token);
            _ = ReadErrorsAsync(child, current, stop.Token);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            deadline.CancelAfter(TimeSpan.FromMinutes(5));
            using var registration = deadline.Token.Register(() => StopGeneration(current,
                new OperationCanceledException("Model loading cancelled.", deadline.Token)));
            try { await completion.Task.WaitAsync(deadline.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            { throw new TimeoutException("The local model took too long to load. Close other memory-heavy apps and try again."); }
        }
        catch { StopGeneration(current, new IOException("Could not load the local model.")); throw; }
    }

    private async Task ReadOutputAsync(Process child, long current, CancellationToken cancellationToken)
    {
        try
        {
            await foreach (var line in ReadLinesAsync(child.StandardOutput, 4 * 1024 * 1024, cancellationToken).ConfigureAwait(false))
            {
                using var document = JsonDocument.Parse(line);
                var value = document.RootElement;
                if (value.ValueKind != JsonValueKind.Object) throw new IOException("Invalid local engine response.");
                lock (sync)
                {
                    if (current != generation) return;
                    if (value.TryGetProperty("ready", out var isReady) && isReady.ValueKind == JsonValueKind.True)
                    { ready?.TrySetResult(true); continue; }
                    if (value.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String)
                    {
                        if (id.GetString() == requestId) response?.TrySetResult(value.Clone());
                    }
                    else if (value.TryGetProperty("error", out var error))
                        throw new IOException(error.GetString() ?? "The local engine failed to start.");
                    else throw new IOException("The local engine returned an unrecognised response.");
                }
            }
            if (!cancellationToken.IsCancellationRequested)
                StopGeneration(current, new IOException("The local engine stopped unexpectedly. Close other memory-heavy apps and retry."));
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { StopGeneration(current, new IOException("The local engine returned invalid data or stopped.", error)); }
    }

    private async Task ReadErrorsAsync(Process child, long current, CancellationToken cancellationToken)
    {
        try
        {
            var buffer = new char[2048];
            int count;
            while ((count = await child.StandardError.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false)) > 0)
                lock (sync)
                {
                    if (current != generation) return;
                    diagnostics += new string(buffer, 0, count);
                    if (diagnostics.Length > 16_384) diagnostics = diagnostics[^16_384..];
                }
        }
        catch (Exception error) when (error is OperationCanceledException or ObjectDisposedException or IOException) { }
    }

    internal static async IAsyncEnumerable<string> ReadLinesAsync(StreamReader reader, int maxLength,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        // Read the underlying pipe, which returns available bytes immediately.
        // StreamReader.ReadAsync(count) may wait to fill count on an open pipe.
        var bytes = new byte[4096]; var buffer = new char[4096];
        var decoder = new UTF8Encoding(false, true).GetDecoder();
        var line = new StringBuilder(); int byteCount;
        while ((byteCount = await reader.BaseStream.ReadAsync(bytes.AsMemory(), cancellationToken).ConfigureAwait(false)) != 0)
        {
            var count = decoder.GetChars(bytes, 0, byteCount, buffer, 0, flush: false);
            for (var i = 0; i < count; ++i)
            {
                if (buffer[i] == '\n')
                { var value = line.ToString().TrimEnd('\r'); line.Clear(); if (value.Length > 0) yield return value; }
                else
                {
                    if (line.Length >= maxLength) throw new IOException("Local engine response exceeded the size limit.");
                    line.Append(buffer[i]);
                }
            }
        }
        if (line.Length > 0) throw new IOException("The local engine returned a truncated response.");
    }

    public void Cancel() => StopGeneration(null, new OperationCanceledException("Local processing cancelled."));

    private void StopGeneration(long? expected, Exception error)
    {
        Process? child; CancellationTokenSource? stop;
        lock (sync)
        {
            if (expected.HasValue && generation != expected) return;
            ++generation; child = process; stop = processCancellation;
            process = null; processCancellation = null; loadedModel = null;
            ready?.TrySetException(error); response?.TrySetException(error);
            ready = null; response = null; requestId = null;
        }
        if (child is not null)
        {
            // Terminate the producer before cancelling pipe reads. On some
            // platforms cancellation of a redirected pipe waits for its read
            // to unblock; reversing this order can deadlock cancellation.
            try { if (!child.HasExited) child.Kill(); } catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        }
        try { stop?.Cancel(); } catch (ObjectDisposedException) { }
        child?.Dispose();
        stop?.Dispose();
    }

    public ValueTask DisposeAsync()
    { disposed = true; Cancel(); return ValueTask.CompletedTask; }
}
