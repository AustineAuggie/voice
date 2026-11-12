using System.Diagnostics;
using System.Security.Cryptography;

namespace Voice.Core;

public sealed class ModelManager : IDisposable
{
    private readonly HttpClient client;
    private readonly bool ownsClient;
    private readonly SemaphoreSlim downloadGate = new(1, 1);
    public AppPaths Paths { get; }

    public ModelManager(AppPaths paths, HttpClient? httpClient = null)
    {
        Paths = paths;
        ownsClient = httpClient == null;
        client = httpClient ?? new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
    }
    public string GetAssetPath(ModelAsset asset) => Paths.ModelPath(asset.Filename);
    // These are inexpensive UI availability indicators. Ensure/Verify checks the
    // full pinned SHA-256 before a model is passed to a native worker.
    public bool HasSpeech(string id) => LooksPresent(ModelCatalog.Speech(id));
    public bool HasEditor => ModelCatalog.EditorModels.All(LooksPresent);
    public bool HasSpeakers => ModelCatalog.SpeakerModels.All(LooksPresent);
    private bool LooksPresent(ModelAsset asset)
    {
        var file = new FileInfo(GetAssetPath(asset));
        return file.Exists && file.Length > 0 && (asset.ArchiveMember != null || asset.Bytes == null || file.Length == asset.Bytes);
    }

    public async Task<bool> VerifyAsync(ModelAsset asset, CancellationToken cancellationToken = default)
    {
        var path = GetAssetPath(asset);
        if (!File.Exists(path)) return false;
        if (asset.ArchiveMember == null && asset.Bytes is long expected && new FileInfo(path).Length != expected) return false;
        return await HasHashAsync(path, asset.ExtractedSha256 ?? asset.Sha256, cancellationToken).ConfigureAwait(false);
    }

    public Task<string> EnsureSpeechAsync(string id, IProgress<ModelProgress>? progress = null, CancellationToken cancellationToken = default)
        => EnsureAsync(ModelCatalog.Speech(id), progress, cancellationToken);
    public async Task<string> EnsureEditorAsync(IProgress<ModelProgress>? progress = null, CancellationToken cancellationToken = default)
    {
        foreach (var asset in ModelCatalog.EditorModels) await EnsureAsync(asset, progress, cancellationToken).ConfigureAwait(false);
        return GetAssetPath(ModelCatalog.EditorModels[0]);
    }
    public async Task<(string Segmentation, string Embedding)> EnsureSpeakersAsync(IProgress<ModelProgress>? progress = null, CancellationToken cancellationToken = default)
    {
        foreach (var asset in ModelCatalog.SpeakerModels) await EnsureAsync(asset, progress, cancellationToken).ConfigureAwait(false);
        return (GetAssetPath(ModelCatalog.SpeakerModels[0]), GetAssetPath(ModelCatalog.SpeakerModels[1]));
    }

    public async Task<string> EnsureAsync(ModelAsset asset, IProgress<ModelProgress>? progress = null, CancellationToken cancellationToken = default)
    {
        var target = GetAssetPath(asset);
        await downloadGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        var token = Guid.NewGuid().ToString("N");
        var temporary = target + "." + token + ".download";
        var extracted = target + "." + token + ".extracted";
        try
        {
            progress?.Report(new(asset.Id, "Checking existing model…", 0, asset.Bytes));
            if (await VerifyAsync(asset, cancellationToken).ConfigureAwait(false)) return target;
            if (!Uri.TryCreate(asset.Url, UriKind.Absolute, out var url) || url.Scheme != Uri.UriSchemeHttps)
                throw new InvalidDataException("Model downloads require HTTPS.");
            AppPaths.EnsurePrivateDirectory(System.IO.Path.GetDirectoryName(target)!);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromHours(6));
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.UserAgent.ParseAdd("Voice-Windows/0.7.0");
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            if (response.RequestMessage?.RequestUri?.Scheme != Uri.UriSchemeHttps)
                throw new InvalidDataException("The model server redirected to an insecure download.");
            if (asset.Bytes is long expected && response.Content.Headers.ContentLength is long actual && expected != actual)
                throw new InvalidDataException("The model download has an unexpected size. The existing model has been retained.");
            var declared = asset.Bytes ?? response.Content.Headers.ContentLength;
            if (declared > asset.MaximumBytes) throw new InvalidDataException("The model download exceeds its permitted size.");
            using (var input = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false))
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 131072, useAsync: true))
            {
                AppPaths.MakePrivate(temporary);
                var buffer = new byte[131072];
                long total = 0;
                int bytes;
                var lastProgress = Stopwatch.StartNew();
                while ((bytes = await input.ReadAsync(buffer.AsMemory(), timeout.Token).ConfigureAwait(false)) != 0)
                {
                    total += bytes;
                    if (total > asset.MaximumBytes || asset.Bytes is long size && total > size)
                        throw new InvalidDataException("The model download exceeds its expected size.");
                    await output.WriteAsync(buffer.AsMemory(0, bytes), timeout.Token).ConfigureAwait(false);
                    if (lastProgress.ElapsedMilliseconds >= 150)
                    {
                        progress?.Report(new(asset.Id, "Downloading " + asset.Filename, total, declared));
                        lastProgress.Restart();
                    }
                }
                if (asset.Bytes is long required && total != required) throw new InvalidDataException("The model download was incomplete.");
                await output.FlushAsync(timeout.Token).ConfigureAwait(false);
                output.Flush(flushToDisk: true);
                progress?.Report(new(asset.Id, "Verifying download…", total, declared));
            }
            if (!await HasHashAsync(temporary, asset.Sha256, timeout.Token).ConfigureAwait(false))
                throw new InvalidDataException("The model checksum did not match. The existing model has been retained; retry the download.");
            var ready = temporary;
            if (asset.ArchiveMember != null)
            {
                if (asset.ExtractedSha256 == null) throw new InvalidDataException("The speaker model is missing its verification checksum.");
                await ExtractMemberAsync(temporary, asset.ArchiveMember, extracted, asset.MaximumBytes, timeout.Token).ConfigureAwait(false);
                if (!await HasHashAsync(extracted, asset.ExtractedSha256, timeout.Token).ConfigureAwait(false))
                    throw new InvalidDataException("The extracted speaker model checksum did not match.");
                ready = extracted;
            }
            timeout.Token.ThrowIfCancellationRequested();
            File.Move(ready, target, overwrite: true);
            AppPaths.MakePrivate(target);
            progress?.Report(new(asset.Id, "Model ready", asset.Bytes ?? new FileInfo(target).Length, asset.Bytes ?? new FileInfo(target).Length));
            return target;
        }
        finally
        {
            TryDelete(temporary);
            TryDelete(extracted);
            downloadGate.Release();
        }
    }

    private static async Task<bool> HasHashAsync(string path, string expected, CancellationToken token)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 131072, useAsync: true);
        var actual = await SHA256.HashDataAsync(file, token).ConfigureAwait(false);
        return Convert.ToHexString(actual).Equals(expected, StringComparison.OrdinalIgnoreCase);
    }
    private static async Task ExtractMemberAsync(string archive, string member, string destination, long limit, CancellationToken token)
    {
        if (System.IO.Path.IsPathRooted(member) || member.Split('/').Any(p => p == "..") || member.StartsWith('-'))
            throw new InvalidDataException("Invalid model archive member.");
        // Windows includes bsdtar. Stream exactly one hash-pinned archive member
        // to our chosen file; never extract archive paths into the file system.
        var executable = OperatingSystem.IsWindows() ? System.IO.Path.Combine(Environment.SystemDirectory, "tar.exe") : "/usr/bin/tar";
        if (!File.Exists(executable)) throw new FileNotFoundException("Windows tar.exe is required to prepare the speaker model. Update Windows, then retry.");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in new[] { "-xOf", archive, member }) start.ArgumentList.Add(argument);
        using var process = new Process { StartInfo = start };
        if (!process.Start()) throw new IOException("The speaker model extractor could not start.");
        using var registration = token.Register(() => { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } });
        var errors = process.StandardError.ReadToEndAsync(token);
        try
        {
            using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 131072, useAsync: true))
            {
                AppPaths.MakePrivate(destination);
                var buffer = new byte[131072];
                long total = 0;
                int bytes;
                while ((bytes = await process.StandardOutput.BaseStream.ReadAsync(buffer.AsMemory(), token).ConfigureAwait(false)) != 0)
                {
                    total += bytes;
                    if (total > limit) throw new InvalidDataException("The extracted model exceeds its permitted size.");
                    await output.WriteAsync(buffer.AsMemory(0, bytes), token).ConfigureAwait(false);
                }
                await output.FlushAsync(token).ConfigureAwait(false);
                output.Flush(flushToDisk: true);
            }
            await process.WaitForExitAsync(token).ConfigureAwait(false);
            _ = await errors.ConfigureAwait(false);
            if (process.ExitCode != 0) throw new InvalidDataException("Windows could not extract the verified speaker model. Retry the model download.");
        }
        catch
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            throw;
        }
    }
    private static void TryDelete(string path) { try { if (File.Exists(path)) File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    public void Dispose() { if (ownsClient) client.Dispose(); downloadGate.Dispose(); }
}
