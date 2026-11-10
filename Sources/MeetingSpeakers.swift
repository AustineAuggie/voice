import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct TimedMeetingText: Decodable {
    var text: String
    var words: [SpeakerWord]
    func validatedWords(duration: Double) -> [SpeakerWord]? {
        guard duration.isFinite, duration >= 0, words.count <= 50_000,
              words.map(\.text).joined() == text else { return nil }
        var last: Double = 0
        for word in words {
            // A native timingValid:false piece still needs safe display bounds.
            // Alignment retains its text and deliberately leaves it unassigned.
            guard word.start.isFinite, word.end.isFinite, word.start >= last,
                  word.end >= word.start, word.start >= 0, word.end <= duration + 0.05 else { return nil }
            last = word.start
        }
        return words
    }
}

protocol MeetingSpeakerProcessing: AnyObject {
    var available: Bool { get }
    func process(record: MeetingRecord, folder: URL, completion: @escaping (Result<[SpeakerSpan], Error>) -> Void)
    func cancel()
}

/// Main-thread coordinator; audio preparation and native inference run off the UI.
/// No audio or transcript is sent over a network connection.
final class MeetingSpeakerProcessor: MeetingSpeakerProcessing {
    private let executable: URL?
    private let models: URL
    private var current: SpeakerJob?
    init(executable: URL? = Bundle.main.url(forResource: "localvoice-diarizer", withExtension: nil),
         models: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LocalVoice/Models/Speakers")) {
        self.executable = executable; self.models = models
    }
    var available: Bool {
        guard let executable = executable else { return false }
        return FileManager.default.isExecutableFile(atPath: executable.path) &&
            ["segmentation.onnx", "embedding.onnx"].allSatisfy { FileManager.default.fileExists(atPath: models.appendingPathComponent($0).path) }
    }
    func process(record: MeetingRecord, folder: URL, completion: @escaping (Result<[SpeakerSpan], Error>) -> Void) {
        cancel()
        guard available, let executable = executable else { completion(.failure(VoiceError("Speaker engine or models are missing. Run the Voice installer again, then retry this meeting."))); return }
        let job = SpeakerJob(); current = job
        let models = models
        DispatchQueue(label: "localvoice.speakers", qos: .userInitiated).async { [weak self] in
            let result = Result { try job.run(record: record, folder: folder, executable: executable, models: models) }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.current === job else { return }
                self.current = nil; completion(result)
            }
        }
    }
    func cancel() { current?.cancel(); current = nil }
    deinit { current?.cancel() }
}

/// Synchronises cancellation across the main and processing queues.
private final class SpeakerJob {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    func cancel() {
        lock.lock(); cancelled = true; let child = process; lock.unlock()
        if let child = child, child.isRunning { child.terminate() }
    }
    func check() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw VoiceError("Speaker processing cancelled. Your meeting is saved.") }
    }
    func run(record: MeetingRecord, folder: URL, executable: URL, models: URL) throws -> [SpeakerSpan] {
        let work = folder.appendingPathComponent(".speakers-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let audio = work.appendingPathComponent("input.f32")
        let maps = try SpeakerAudio.prepare(record: record, folder: folder, output: audio, check: check)
        guard let last = maps.last else {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(SpeakerDiagnostics.filename))
            return []
        }
        try check()
        let output = work.appendingPathComponent("result.json"), errors = work.appendingPathComponent("engine.log")
        guard FileManager.default.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw VoiceError("Could not prepare the speaker engine log.") }
        let log = try FileHandle(forWritingTo: errors); defer { try? log.close() }
        let child = Process(); child.executableURL = executable
        child.arguments = ["--segmentation", models.appendingPathComponent("segmentation.onnx").path,
                           "--embedding", models.appendingPathComponent("embedding.onnx").path,
                           "--audio", audio.path, "--output", output.path, "--threads", "2"]
        child.standardOutput = FileHandle.nullDevice; child.standardError = log; child.standardInput = FileHandle.nullDevice
        lock.lock(); process = child
        do { if cancelled { throw VoiceError("Speaker processing cancelled.") }; try child.run(); lock.unlock() }
        catch { process = nil; lock.unlock(); throw error }
        defer { lock.lock(); process = nil; lock.unlock() }
        let started = Date(), timeout = max(180, min(14_400, last.inputEnd * 2))
        var stoppedAt: Date?
        while child.isRunning {
            lock.lock(); let stop = cancelled; lock.unlock()
            if stop || Date().timeIntervalSince(started) > timeout {
                if stoppedAt == nil { stoppedAt = Date(); child.terminate() }
                if let stoppedAt = stoppedAt, Date().timeIntervalSince(stoppedAt) > 2 { _ = kill(child.processIdentifier, SIGKILL) }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        child.waitUntilExit(); try check()
        guard stoppedAt == nil else { throw VoiceError("Speaker processing timed out. The original transcript and audio are saved for retry.") }
        guard child.terminationStatus == 0 else {
            let tail = SpeakerDiagnostics.tail(of: errors)
            let reason = SpeakerDiagnostics.reason(in: tail)
            let saved = SpeakerDiagnostics.save(folder: folder, models: models, status: child.terminationStatus,
                                                signalled: child.terminationReason == .uncaughtSignal, reason: reason, log: tail)
            throw VoiceError(SpeakerDiagnostics.message(reason: reason, status: child.terminationStatus) +
                (saved ? " Use Copy speaker diagnostics in the meeting menu for details." : "") +
                " The original transcript and audio are saved for retry.")
        }
        let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= 32_000_000 else { throw VoiceError("Invalid speaker engine response.") }
        let spans = try SpeakerAudio.map(try Data(contentsOf: output), through: maps)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(SpeakerDiagnostics.filename))
        return spans
    }
}

/// A bounded local engine log, separate from the transcript and never included in
/// meeting exports. Only explicit Copy speaker diagnostics places it on the clipboard.
enum SpeakerDiagnostics {
    static let filename = "speaker-diagnostic.txt"
    private static let explanations = [
        "invalid-audio": "Speaker analysis found damaged or non-finite audio samples.",
        "read-audio": "The speaker engine could not read the saved meeting audio.",
        "write-result": "The speaker engine could not save its result. Check available disk space.",
        "invalid-options": "The speaker engine and app disagree on their settings. Reinstall Voice.",
        "missing-models": "Speaker model files are missing. Run the Voice installer again.",
        "model-init": "The local speaker models could not load. Run the Voice installer to verify their files.",
        "sample-rate": "The installed speaker model is incompatible. Run the Voice installer again.",
        "no-result": "The speaker engine returned no analysis result.",
        "invalid-result": "The speaker engine returned an invalid analysis result.",
        "memory-limit": "There was not enough memory for speaker analysis. Close memory-heavy apps and retry.",
        "unexpected": "The local speaker engine stopped unexpectedly."
    ]
    static func tail(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end > 16_384 ? end - 16_384 : 0)
            return String(decoding: try handle.read(upToCount: 16_384) ?? Data(), as: UTF8.self)
        } catch { return "" }
    }
    static func reason(in log: String) -> String {
        for line in log.split(separator: "\n").reversed() where line.hasPrefix("speaker-error ") {
            let value = String(line.dropFirst("speaker-error ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if explanations[value] != nil { return value }
        }
        // Old workers and native library failures may exit before emitting a marker.
        return "unexpected"
    }
    static func message(reason: String, status: Int32) -> String {
        (explanations[reason] ?? explanations["unexpected"]!) + " [\(reason), exit \(status)]"
    }
    static func save(folder: URL, models: URL, status: Int32, signalled: Bool, reason: String, log: String) -> Bool {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        var safeLog = String(log.suffix(16_384))
        // Native stderr contains model/file diagnostics, not transcript text. Redact
        // private paths before saving the shareable excerpt. No audio bytes are read.
        for (path, replacement) in [(folder.path, "<meeting>"), (models.path, "<speaker-models>"),
                                     (FileManager.default.homeDirectoryForCurrentUser.path, "~")] where !path.isEmpty {
            safeLog = safeLog.replacingOccurrences(of: path, with: replacement)
        }
        safeLog = String(safeLog.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" })
        let report = "Voice speaker diagnostics\nApp version: \(version)\nSystem: \(ProcessInfo.processInfo.operatingSystemVersionString)\nReason: \(reason)\nExit: \(status)\nTerminated by signal: \(signalled)\n\nEngine stderr (last 16 KiB; private paths redacted):\n\(safeLog)\n"
        let target = folder.appendingPathComponent(filename)
        do {
            try report.write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return true
        } catch { return false }
    }
}

enum SpeakerAudio {
    struct Mapping { var track: MeetingTrack; var start: Double; var inputStart: Double; var duration: Double; var inputEnd: Double { inputStart + duration } }
    /// Concatenate sources for one global clustering pass. Each mapping preserves
    /// original meeting time; overlap at journal chunk boundaries is written once.
    static func prepare(record: MeetingRecord, folder: URL, output: URL, check: () throws -> Void = {}) throws -> [Mapping] {
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw VoiceError("Could not prepare speaker audio.") }
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        var maps: [Mapping] = [], inputFrames = 0
        let silence = Data(repeating: 0, count: 16000 * 4)
        for track in [MeetingTrack.microphone, .computer] {
            var covered: Double?
            for chunk in record.sortedChunks where chunk.track == track {
                try check()
                guard chunk.start.isFinite, chunk.start >= 0, chunk.duration.isFinite, chunk.duration > 0,
                      chunk.filename == URL(fileURLWithPath: chunk.filename).lastPathComponent,
                      chunk.filename.hasSuffix(".f32"), chunk.filename.contains(chunk.id.uuidString) else { throw VoiceError("Invalid meeting audio for speaker analysis.") }
                let file = folder.appendingPathComponent(chunk.filename)
                guard file.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path == folder.resolvingSymlinksInPath().standardizedFileURL.path else { throw VoiceError("Speaker audio path leaves the meeting folder.") }
                let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size > 0, size % 4 == 0, size <= 24 * 16000 * 4 else { throw VoiceError("Meeting audio has an invalid size.") }
                let data = try Data(contentsOf: file)
                guard data.count > 0, data.count % 4 == 0, data.count <= 24 * 16000 * 4,
                      abs(Double(data.count / 4) / 16000 - chunk.duration) < 0.01 else { throw VoiceError("Meeting audio is incomplete. Keep the existing transcript and retry with the original audio.") }
                let skip = max(0, Int((((covered ?? chunk.start) - chunk.start) * 16000).rounded()))
                guard skip < data.count / 4 else { continue }
                if !maps.isEmpty && (covered == nil || chunk.start - covered! > 0.3) {
                    try handle.write(contentsOf: silence); inputFrames += 16000
                }
                let frames = data.count / 4 - skip
                // Bound native memory use; this is an audio-duration guard, not a
                // speaker-count limit. Ordinary transcription remains available.
                guard inputFrames + frames <= 6 * 3600 * 16000 else { throw VoiceError("This meeting has over six hours of combined audio tracks. The transcript is kept; automatic speaker analysis could not run in one pass.") }
                try handle.write(contentsOf: data.dropFirst(skip * 4))
                maps.append(Mapping(track: track, start: chunk.start + Double(skip) / 16000, inputStart: Double(inputFrames) / 16000, duration: Double(frames) / 16000))
                inputFrames += frames; covered = max(covered ?? 0, chunk.end)
            }
        }
        try handle.synchronize(); return maps
    }
    static func map(_ data: Data, through maps: [Mapping]) throws -> [SpeakerSpan] {
        struct Segment: Decodable { var start: Double; var end: Double; var speaker: Int }
        struct Response: Decodable { var sample_rate: Int; var num_speakers: Int; var segments: [Segment] }
        let value = try JSONDecoder().decode(Response.self, from: data)
        guard value.sample_rate == 16000, value.num_speakers >= 0, value.segments.count <= 200_000 else { throw VoiceError("Invalid speaker result format.") }
        var spans: [SpeakerSpan] = []
        for segment in value.segments {
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end > segment.start,
                  segment.end <= (maps.last?.inputEnd ?? 0) + 0.1, segment.speaker >= 0, segment.speaker < value.num_speakers else { throw VoiceError("Invalid speaker result timing or label.") }
            for mapping in maps where mapping.inputStart < segment.end && mapping.inputEnd > segment.start {
                let start = max(segment.start, mapping.inputStart), end = min(segment.end, mapping.inputEnd)
                if end > start { spans.append(SpeakerSpan(track: mapping.track, start: mapping.start + start - mapping.inputStart, end: mapping.start + end - mapping.inputStart, speaker: segment.speaker)) }
            }
        }
        return spans
    }
}
