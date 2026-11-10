import Foundation
import CryptoKit

enum AppPaths {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalVoice", isDirectory: true)
    }
    static var models: URL { root.appendingPathComponent("Models", isDirectory: true) }
    static var sessions: URL { root.appendingPathComponent("Sessions", isDirectory: true) }
    static func prepare() throws {
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
    static func modelURL(_ model: SpeechModel) -> URL { models.appendingPathComponent(model.filename) }
    static func hasModel(_ model: SpeechModel) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: modelURL(model).path),
              let bytes = attributes[.size] as? NSNumber else { return false }
        return bytes.int64Value == model.byteCount
    }
    static var engine: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let file = resources.appendingPathComponent("localvoice-speech")
        return FileManager.default.isExecutableFile(atPath: file.path) ? file : nil
    }
    static var editor: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let file = resources.appendingPathComponent("localvoice-editor")
        return FileManager.default.isExecutableFile(atPath: file.path) ? file : nil
    }
    static var editorModel: URL { models.appendingPathComponent("qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf") }
    static var hasEditorModel: Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: editorModel.path),
              let b = try? FileManager.default.attributesOfItem(atPath: models.appendingPathComponent("qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf").path) else { return false }
        return (a[.size] as? NSNumber)?.int64Value == 3_993_201_344 && (b[.size] as? NSNumber)?.int64Value == 689_872_288
    }
    static func newSession() throws -> URL {
        try prepare()
        let folder = sessions.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return folder
    }
    static func clearAbandonedSessions() {
        // Only this application's private, generated session folders are removed.
        if let folders = try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil) {
            for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}

final class ModelDownload: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private let model: SpeechModel
    private let onProgress: (Double, String) -> Void
    private let onComplete: (Result<Void, Error>) -> Void
    private var completed = false // Accessed only on the serial delegate queue.

    init(model: SpeechModel, progress: @escaping (Double, String) -> Void,
         completion: @escaping (Result<Void, Error>) -> Void) {
        self.model = model; self.onProgress = progress; self.onComplete = completion
    }
    func start() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 6
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        task = session?.downloadTask(with: model.downloadURL)
        task?.resume()
    }
    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : model.byteCount
        let progress = min(1, Double(totalBytesWritten) / Double(total))
        let label = ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file)
        DispatchQueue.main.async { self.onProgress(progress, "Downloaded \(label)") }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                throw VoiceError("The model download failed. Check your connection and try again.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == model.byteCount else {
                throw VoiceError("The downloaded model has the wrong size. Please download it again.")
            }
            DispatchQueue.main.async { self.onProgress(1, "Verifying download…") }
            let handle = try FileHandle(forReadingFrom: location)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
            let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard hex == model.sha256 else { throw VoiceError("The model checksum did not match. Please retry the download.") }
            try AppPaths.prepare()
            let target = AppPaths.modelURL(model)
            // Existing invalid file is removed only after the new download is verified.
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: location, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            finish(Result<Void, Error>.success(Void()))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error { finish(.failure(error)) }
        session.finishTasksAndInvalidate()
        self.session = nil; self.task = nil
    }
    private func finish(_ result: Result<Void, Error>) {
        guard !completed else { return }
        completed = true
        DispatchQueue.main.async { self.onComplete(result) }
    }
}
