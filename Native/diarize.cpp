// LocalVoice offline diarization worker. Uses the pinned sherpa-onnx C API.
// Input: mono 16 kHz little-endian float32 PCM. No network access is performed.
#include "sherpa-c-api.h"
#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {
// Stable, non-sensitive markers let the app explain a failure without copying
// third-party stderr, filenames or meeting data into the interface.
struct SpeakerError : std::runtime_error {
    const char *code;
    SpeakerError(const char *code, const char *message) : std::runtime_error(message), code(code) {}
};
struct Audio {
    int fd = -1;
    void *mapped = MAP_FAILED;
    size_t bytes = 0;
    explicit Audio(const std::string &path) {
        fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW);
        if (fd < 0) throw SpeakerError("read-audio", "Could not open meeting audio.");
        struct stat info{};
        if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_size < 0 || info.st_size % 4 != 0 ||
            uint64_t(info.st_size) / sizeof(float) > uint64_t(std::numeric_limits<int32_t>::max())) {
            close(fd); fd = -1; throw SpeakerError("invalid-audio", "Invalid or oversized float32 meeting audio.");
        }
        bytes = size_t(info.st_size);
        if (bytes) {
            mapped = mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
            if (mapped == MAP_FAILED) { close(fd); fd = -1; throw SpeakerError("read-audio", "Cannot map meeting audio into memory."); }
        }
    }
    ~Audio() { if (mapped != MAP_FAILED) munmap(mapped, bytes); if (fd >= 0) close(fd); }
    const float *samples() const { return static_cast<const float *>(mapped); }
    int32_t size() const { return int32_t(bytes / sizeof(float)); }
    bool prepare() {
        double peak = 0;
        for (int32_t i = 0; i < size(); ++i) {
            const float x = samples()[i];
            if (!std::isfinite(x)) throw SpeakerError("invalid-audio", "Meeting audio contains non-finite samples.");
            peak = std::max(peak, std::abs(double(x)));
        }
        // Floating-point capture/resampling can exceed full scale. Rejecting a
        // whole meeting for one such sample loses otherwise usable speech.
        // Attenuate uniformly in this process's private mapping, preserving the
        // waveform and leaving the stored original byte-for-byte unchanged.
        if (peak > 1) {
            float *writable = static_cast<float *>(mapped);
            for (int32_t i = 0; i < size(); ++i) writable[i] = float(double(writable[i]) / peak);
            std::cerr << "speaker-audio-normalized\n";
        }
        return peak > 0;
    }
};
int number(const std::string &text) {
    try {
        size_t used = 0; const int result = std::stoi(text, &used);
        if (used != text.size()) throw SpeakerError("invalid-options", "Expected an integer option.");
        return result;
    } catch (const std::invalid_argument &) {
        throw SpeakerError("invalid-options", "Expected an integer option.");
    } catch (const std::out_of_range &) {
        throw SpeakerError("invalid-options", "Integer option is out of range.");
    }
}
void writeResult(const std::string &path, const std::string &json) {
    const std::string temporary = path + ".pending-" + std::to_string(getpid());
    int fd = open(temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) throw SpeakerError("write-result", "Could not create speaker result file.");
    try {
        size_t written = 0;
        while (written < json.size()) {
            const ssize_t n = write(fd, json.data() + written, json.size() - written);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) throw SpeakerError("write-result", "Could not write speaker result file.");
            written += size_t(n);
        }
        if (fsync(fd)) throw SpeakerError("write-result", "Could not save speaker result file.");
        close(fd); fd = -1;
        if (rename(temporary.c_str(), path.c_str())) throw SpeakerError("write-result", "Could not finish speaker result file.");
    } catch (...) { if (fd >= 0) close(fd); unlink(temporary.c_str()); throw; }
}
int32_t progress(int32_t done, int32_t total, void *) {
    if (done == total || done % 25 == 0) std::cerr << "speaker-progress " << done << " " << total << '\n';
    return 0;
}
}

int main(int argc, char **argv) {
    try {
        std::map<std::string, std::string> options;
        for (int i = 1; i < argc; i += 2) {
            if (i + 1 >= argc) throw SpeakerError("invalid-options", "Missing option value.");
            const std::string key(argv[i]);
            if (key != "--audio" && key != "--output" && key != "--segmentation" && key != "--embedding" && key != "--speakers" && key != "--threads")
                throw SpeakerError("invalid-options", "Unknown diarization option.");
            if (!options.emplace(key, argv[i + 1]).second) throw SpeakerError("invalid-options", "Repeated diarization option.");
        }
        for (const auto *key : {"--audio", "--output", "--segmentation", "--embedding"})
            if (!options.count(key) || options[key].empty()) throw SpeakerError("invalid-options", "Missing required diarization option.");
        const int speakers = options.count("--speakers") ? number(options["--speakers"]) : -1;
        const int threads = options.count("--threads") ? number(options["--threads"]) : 2;
        if ((speakers != -1 && speakers < 1) || threads < 1 || threads > 16) throw SpeakerError("invalid-options", "Invalid speaker count or thread count.");
        Audio audio(options["--audio"]);
        // Avoid model corner cases on empty or exactly silent recordings.
        if (!audio.prepare()) {
            writeResult(options["--output"], "{\"sample_rate\":16000,\"num_speakers\":0,\"segments\":[]}\n"); return 0;
        }
        for (const auto *key : {"--segmentation", "--embedding"})
            if (!std::ifstream(options[key], std::ios::binary).good()) throw SpeakerError("missing-models", "Speaker models are missing; run LocalVoice setup again.");
        SherpaOnnxOfflineSpeakerDiarizationConfig config{};
        config.segmentation.pyannote.model = options["--segmentation"].c_str();
        config.segmentation.pyannote.window_shift_ratio = 0.1f;
        config.segmentation.num_threads = threads; config.segmentation.provider = "cpu";
        config.embedding.model = options["--embedding"].c_str();
        config.embedding.num_threads = threads; config.embedding.provider = "cpu";
        config.clustering.num_clusters = speakers; // -1: estimate any number of speakers.
        config.clustering.threshold = 0.4f;
        config.clustering.compute_confidence = 1;
        config.min_duration_on = 0.2f; config.min_duration_off = 0.3f;
        using D = std::unique_ptr<const SherpaOnnxOfflineSpeakerDiarization, decltype(&SherpaOnnxDestroyOfflineSpeakerDiarization)>;
        D diarizer(SherpaOnnxCreateOfflineSpeakerDiarization(&config), SherpaOnnxDestroyOfflineSpeakerDiarization);
        if (!diarizer) throw SpeakerError("model-init", "Could not initialise the local speaker model.");
        if (SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(diarizer.get()) != 16000) throw SpeakerError("sample-rate", "Speaker model sample rate is incompatible.");
        using R = std::unique_ptr<const SherpaOnnxOfflineSpeakerDiarizationResult, decltype(&SherpaOnnxOfflineSpeakerDiarizationDestroyResult)>;
        R result(SherpaOnnxOfflineSpeakerDiarizationProcessWithCallback(diarizer.get(), audio.samples(), audio.size(), progress, nullptr), SherpaOnnxOfflineSpeakerDiarizationDestroyResult);
        if (!result) throw SpeakerError("no-result", "Speaker analysis returned no result.");
        const int32_t count = SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result.get());
        if (count < 0) throw SpeakerError("invalid-result", "Speaker analysis returned invalid segments.");
        using S = std::unique_ptr<const SherpaOnnxOfflineSpeakerDiarizationSegment, decltype(&SherpaOnnxOfflineSpeakerDiarizationDestroySegment)>;
        S segments(SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result.get()), SherpaOnnxOfflineSpeakerDiarizationDestroySegment);
        if (count && !segments) throw SpeakerError("invalid-result", "Speaker segments are unavailable.");
        std::map<int32_t, int32_t> labels;
        std::ostringstream json;
        json << std::setprecision(8) << "{\"sample_rate\":16000,\"segments\":[";
        bool first = true;
        const double duration = double(audio.size()) / 16000;
        for (int32_t i = 0; i < count; ++i) {
            const auto &s = segments.get()[i];
            if (!std::isfinite(s.start) || !std::isfinite(s.end) || s.speaker < 0 || s.end <= s.start) continue;
            const double start = std::max(0.0, double(s.start)), end = std::min(duration, double(s.end));
            if (end <= start) continue;
            const auto inserted = labels.emplace(s.speaker, int32_t(labels.size()));
            if (!first) json << ','; first = false;
            json << "{\"start\":" << start << ",\"end\":" << end << ",\"speaker\":" << inserted.first->second << ",\"confidence\":";
            if (std::isfinite(s.confidence) && s.confidence >= -1 && s.confidence <= 1) json << s.confidence;
            else json << "null";
            json << '}';
        }
        json << "],\"num_speakers\":" << labels.size() << "}\n";
        writeResult(options["--output"], json.str());
        return 0;
    } catch (const SpeakerError &error) {
        std::cerr << "speaker-error " << error.code << '\n';
        std::cerr << "LocalVoice speaker analysis: " << error.what() << '\n'; return 1;
    } catch (const std::bad_alloc &) {
        std::cerr << "speaker-error memory-limit\n";
        std::cerr << "LocalVoice speaker analysis: Not enough memory for speaker analysis.\n"; return 1;
    } catch (const std::exception &error) {
        std::cerr << "speaker-error unexpected\n";
        std::cerr << "LocalVoice speaker analysis: " << error.what() << '\n'; return 1;
    }
}
