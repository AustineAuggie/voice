import Foundation

@main enum SpeakerProcessTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1; if !value { fatalError(message) }
        }
        func spin(_ done: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !done() && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            check(done(), "Speaker process callback timed out")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-process-" + UUID().uuidString)
        let models = root.appendingPathComponent("models"), folder = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = models.appendingPathComponent("segmentation.onnx")
        try "dummy".write(to: models.appendingPathComponent("embedding.onnx"), atomically: true, encoding: .utf8)
        var record = MeetingRecord(title: "PRIVATE MEETING TITLE", source: .online, language: "en", model: "largeV3Turbo", keepAudio: true, vocabulary: "PRIVATE DICTIONARY")
        let id = UUID(), name = MeetingChunk.name(id: id, track: .microphone, start: 0, partial: false)
        let original = [Float](repeating: 0.5, count: 16000).withUnsafeBytes { Data($0) }
        let input = folder.appendingPathComponent(name)
        try original.write(to: input)
        record.chunks = [MeetingChunk(id: id, track: .microphone, start: 0, duration: 1, filename: name, text: "PRIVATE TRANSCRIPT")]
        let processor = MeetingSpeakerProcessor(executable: URL(fileURLWithPath: CommandLine.arguments[1]), models: models)
        func run(_ mode: String) throws -> Result<[SpeakerSpan], Error> {
            try mode.write(to: model, atomically: true, encoding: .utf8)
            var answer: Result<[SpeakerSpan], Error>?
            processor.process(record: record, folder: folder) { result in
                check(Thread.isMainThread, "Speaker callbacks run on main thread")
                answer = result
            }
            spin { answer != nil }; return answer!
        }
        let failure = try run("failure")
        guard case .failure(let error) = failure else { fatalError("Failed worker must fail the request") }
        check(error.localizedDescription.contains("models could not load"), "Known engine marker gives an actionable explanation")
        check(error.localizedDescription.contains("model-init, exit 1"), "Failure retains a useful stable reason and exit status")
        check(!error.localizedDescription.contains(root.path), "Error shown in UI contains no private path")
        let diagnosticURL = folder.appendingPathComponent(SpeakerDiagnostics.filename)
        var diagnostic = try String(contentsOf: diagnosticURL, encoding: .utf8)
        check(diagnostic.contains("speaker-error model-init"), "Native error details survive work-folder cleanup")
        check(diagnostic.contains("<meeting>") && diagnostic.contains("<speaker-models>"), "Engine log paths are redacted")
        check(!diagnostic.contains(root.path), "Shareable diagnostics exclude the user's file path")
        check(!diagnostic.contains("PRIVATE"), "Diagnostic does not include title, dictionary or transcript")
        let permissions = try FileManager.default.attributesOfItem(atPath: diagnosticURL.path)[.posixPermissions] as! NSNumber
        check(permissions.intValue & 0o777 == 0o600, "Diagnostic log is private to the account")
        check(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".speakers-") }.isEmpty, "Failed worker removes its temporary audio directory")
        check(try Data(contentsOf: input) == original, "Failure preserves source audio bytes")
        let unknown = try run("unknown")
        guard case .failure(let unknownError) = unknown else { fatalError("Unknown exit must fail") }
        check(unknownError.localizedDescription.contains("unexpected, exit 9"), "Unknown library exit is reported without inventing a cause")
        diagnostic = try String(contentsOf: diagnosticURL, encoding: .utf8)
        check(diagnostic.utf8.count < 18000 && diagnostic.contains("Unknown native fault"), "Only bounded stderr tail is kept")
        check(SpeakerDiagnostics.reason(in: "speaker-error not-a-known-code") == "unexpected", "Unrecognised marker cannot become arbitrary UI text")
        check(SpeakerDiagnostics.reason(in: "speaker-error model-init\nspeaker-error memory-limit\n") == "memory-limit", "Last known error marker wins")

        try "slow".write(to: model, atomically: true, encoding: .utf8)
        var staleCallbacks = 0
        processor.process(record: record, folder: folder) { _ in staleCallbacks += 1 }
        let pause = Date().addingTimeInterval(0.15)
        while Date() < pause { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        processor.cancel()
        let recovered = try run("success")
        guard case .success(let spans) = recovered else { fatalError("Retry must succeed") }
        check(spans.count == 2 && Set(spans.map(\.speaker)) == Set([0,1]), "Retry maps multiple native speaker labels")
        check(staleCallbacks == 0, "Cancelled old worker cannot finish a new request")
        check(!FileManager.default.fileExists(atPath: diagnosticURL.path), "Successful retry removes stale failure diagnostic")
        check(try Data(contentsOf: input) == original, "Retry preserves original audio")
        check(!record.export.contains("Voice speaker diagnostics"), "Ordinary meeting exports do not include engine diagnostics")
        print("Passed \(checks) speaker process, diagnostic privacy and retry checks.")
    }
}
