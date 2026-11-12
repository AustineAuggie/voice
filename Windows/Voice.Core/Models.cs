namespace Voice.Core;

public sealed class VoiceSettings
{
    public string SpeechModelId { get; set; } = "turbo";
    public string Language { get; set; } = "auto";
    public bool CleanMode { get; set; }
    public bool MuteWhileDictating { get; set; }
    public bool SuggestMeetings { get; set; } = true;
    public bool KeepMeetingAudio { get; set; } = true;
    public bool AnalyzeSpeakers { get; set; } = true;
    public bool GenerateSummary { get; set; } = true;
}

public sealed record VocabularyEntry(string Heard, string Preferred);
public sealed record AudioPart(string Path, string Source, double StartSeconds, double DurationSeconds);
public sealed record TranscriptSegment(double StartSeconds, double EndSeconds, string Text, string SpeakerLabel);
public sealed record HistoryEntry(Guid Id, DateTimeOffset CreatedAt, string Text, string Mode);

public sealed class MeetingRecord
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "Meeting";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.Now;
    public string Status { get; set; } = "Recorded";
    public string Notes { get; set; } = "";
    public string Summary { get; set; } = "";
    public List<TranscriptSegment> Transcript { get; set; } = [];
    public List<AudioPart> AudioParts { get; set; } = [];
    public Dictionary<string, string> SpeakerNames { get; set; } = [];
    public string? Error { get; set; }
}

public sealed record ModelAsset(string Id, string Filename, string Url, string Sha256, long? Bytes,
    string? ArchiveMember = null, string? ExtractedSha256 = null, long MaximumBytes = 8_000_000_000);
public sealed record ModelProgress(string ModelId, string Message, long DownloadedBytes, long? TotalBytes)
{
    public double? Fraction => TotalBytes is > 0 ? Math.Clamp((double)DownloadedBytes / TotalBytes.Value, 0, 1) : null;
}

public static class ModelCatalog
{
    public static readonly IReadOnlyList<ModelAsset> SpeechModels = new[]
    {
        new ModelAsset("turbo", "ggml-large-v3-turbo.bin", "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin", "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69", 1_624_555_275),
        new ModelAsset("large", "ggml-large-v3.bin", "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin", "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2", 3_095_033_483),
        new ModelAsset("base.en", "ggml-base.en.bin", "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.en.bin", "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002", 147_964_211)
    };
    public static readonly IReadOnlyList<ModelAsset> EditorModels = new[]
    {
        new ModelAsset("editor-1", "qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf", "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/bb5d59e06d9551d752d08b292a50eb208b07ab1f/qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf", "dfce12e3862a5283ccfb88221b48480e58745165de856439950d0f22590580db", 3_993_201_344),
        new ModelAsset("editor-2", "qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf", "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/bb5d59e06d9551d752d08b292a50eb208b07ab1f/qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf", "539cf93f78e887edea1c04e2d7d8cdaca9d01dae9c9025bcb8accbe29df3d72a", 689_872_288)
    };
    public static readonly IReadOnlyList<ModelAsset> SpeakerModels = new[]
    {
        new ModelAsset("segmentation", "Speakers/segmentation.onnx", "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2", "24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488", null, "sherpa-onnx-pyannote-segmentation-3-0/model.onnx", "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079", 200_000_000),
        new ModelAsset("embedding", "Speakers/embedding.onnx", "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34.onnx", "5ef208a9da1453335308a6b6f4e6dfbd7e183a38b604de0a57664f45d257fe94", null, MaximumBytes: 200_000_000)
    };
    public static ModelAsset Speech(string id) => SpeechModels.FirstOrDefault(m => m.Id == id)
        ?? throw new ArgumentException("Choose a supported speech model.", nameof(id));
}
