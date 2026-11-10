#include "whisper.h"
#include "WorkerLoop.hpp"
#include <fstream>
#include <iostream>
#include <vector>
#include <cmath>
#include <thread>
#include <chrono>
#include <algorithm>
using json = nlohmann::json;
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    auto options = whisper_context_default_params(); options.use_gpu = true;
    auto ctx = whisper_init_from_file_with_params(argv[1], options);
    if (!ctx) { std::cout << "{\"error\":\"Speech model could not load.\"}" << std::endl; return 1; }
    serve_worker([&](const json &req, std::atomic<bool> &cancelled) -> json {
            // Meeting requests keep the existing text-only IPC envelope, with
            // a versioned JSON payload inside text. Ordinary dictation is
            // unchanged and does not enable the extra timestamp work.
            const bool timed=req.value("timed",false);
            std::ifstream f(req.at("audio").get<std::string>(), std::ios::binary | std::ios::ate);
            if (!f) throw std::runtime_error("Recording file is unavailable.");
            auto size = f.tellg();
            if (size <= 0 || size % 4 != 0 || size > 16000LL*4*3600) throw std::runtime_error("Invalid recording size.");
            std::vector<float> audio(static_cast<size_t>(size)/4);
            f.seekg(0); f.read(reinterpret_cast<char *>(audio.data()), size);
            if (!f) throw std::runtime_error("Incomplete recording file.");
            // Whole-file RMS can erase quiet words surrounded by long pauses.
            // Require several audible 20 ms windows instead of averaging the
            // entire recording down towards silence. Whisper handles speech VAD.
            double energy = 0; int frameSamples=0, audibleFrames=0;
            for (auto x: audio) {
                if (!std::isfinite(x)) throw std::runtime_error("Invalid audio sample.");
                energy += x*x;
                if (++frameSamples==320) {
                    if (std::sqrt(energy/frameSamples)>=0.0008) ++audibleFrames;
                    energy=0; frameSamples=0;
                }
            }
            if (frameSamples && std::sqrt(energy/frameSamples)>=0.0008) ++audibleFrames;
            if (audibleFrames < 3) {
                return {{"text", timed ? json({{"version", 1}, {"text", ""}, {"words", json::array()}}).dump() : ""}};
            }
            const double recordingSeconds=double(audio.size())/16000.0;
            if (audio.size() < 16000) audio.resize(16000,0);
            std::string lang=req.value("language","en"), prompt=req.value("prompt","");
            const bool accuracy=req.value("accuracy",false);
            auto p=whisper_full_default_params(accuracy ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY);
            if (accuracy) { p.beam_search.beam_size=5; p.greedy.best_of=5; }
            p.n_threads=std::max(1,std::min(6,int(std::thread::hardware_concurrency())-2));
            // detect_language=true is detection ONLY in whisper.cpp. A null
            // language detects the language and then continues transcription.
            p.translate=false; p.language=lang=="auto" ? nullptr : lang.c_str(); p.detect_language=false;
            p.no_context=true; p.no_timestamps=true; p.print_progress=false;
            if (timed) {
                // whisper.cpp v1.7.6 uses token-level timing to wrap results
                // into whole-word segments. Reading token byte strings
                // individually can split UTF-8; use complete segment text.
                p.no_timestamps=false; p.token_timestamps=true;
                p.max_len=1; p.split_on_word=true;
            }
            p.print_realtime=false; p.print_timestamps=false; p.print_special=false;
            p.suppress_nst=true; p.initial_prompt=prompt.c_str();
            p.abort_callback = [](void *data) { return static_cast<std::atomic<bool> *>(data)->load(); };
            p.abort_callback_user_data = &cancelled;
            if (cancelled.load()) throw std::runtime_error("Dictation cancelled.");
            auto start=std::chrono::steady_clock::now();
            if (whisper_full(ctx,p,audio.data(),int(audio.size()))) throw std::runtime_error("Speech decoding failed.");
            std::string text;
            json words=json::array(); double previousStart=0;
            for (int i=0;i<whisper_full_n_segments(ctx);i++) {
                std::string piece=whisper_full_get_segment_text(ctx,i);
                text+=piece;
                if (!timed || piece.empty()) continue;
                const double first=whisper_full_get_segment_t0(ctx,i)/100.0;
                const double last=whisper_full_get_segment_t1(ctx,i)/100.0;
                const bool valid=std::isfinite(first) && std::isfinite(last) && first>=0 &&
                    last>first && first>=previousStart && last<=recordingSeconds;
                // Whisper occasionally emits a zero-length word or a trailing
                // endpoint beyond the recording. Keep all recognised text and
                // all other words' genuine timings. Invalid pieces get only a
                // safe display anchor and MUST NOT be assigned to a speaker.
                const double displayStart=std::isfinite(first) ? std::max(previousStart, std::clamp(first, 0.0, recordingSeconds)) : previousStart;
                const double displayEnd=std::isfinite(last) ? std::max(displayStart, std::clamp(last, 0.0, recordingSeconds)) : displayStart;
                words.push_back({{"text", piece}, {"start", displayStart}, {"end", displayEnd}, {"timingValid", valid}});
                previousStart=displayStart;
            }
            auto elapsed=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
            if (timed) {
                // The app marks timingValid=false pieces as "Unclear speaker";
                // a bad timestamp must not discard the rest of this chunk.
                return {{"text", json({{"version", 1}, {"text", text}, {"words", words}}).dump()}, {"seconds", elapsed}};
            }
            return {{"text", text}, {"seconds", elapsed}};
    });
    whisper_free(ctx);
}
