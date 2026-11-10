import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Main-thread owned, private JSON-lines IPC; no network server.
final class LocalWorker {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var bytes = Data()
    private var generation = UUID()
    private var loadedModel: URL?
    private var isReady = false
    private var warmCallbacks: [(Result<Void, Error>) -> Void] = []
    private var pending: (id: String, completion: (Result<String, Error>) -> Void)?
    private var queued: [(payload: [String: Any], timeout: Double, completion: (Result<String, Error>) -> Void)] = []
    var ready: Bool { isReady && process?.isRunning == true }
    func warm(executable: URL?, model: URL, completion: @escaping (Result<Void, Error>) -> Void = { _ in }) {
        if loadedModel == model, process?.isRunning == true {
            if isReady { completion(.success(())) } else { warmCallbacks.append(completion) }; return
        }
        stop()
        guard let executable = executable, FileManager.default.fileExists(atPath: model.path) else {
            completion(.failure(VoiceError("Local engine or model is missing. Run the upgrade installer."))); return
        }
        generation = UUID(); let token = generation
        loadedModel = model; warmCallbacks.append(completion)
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable; child.arguments = [model.path]
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        do { try child.run() } catch { try? output?.close(); fail(error.localizedDescription); return }
        let reader = stdout.fileHandleForReading
        // Only this queue reads/closes its handle. Closing it from stop() can race
        // an active FileHandle callback on macOS and break a subsequent recording.
        DispatchQueue(label: "localvoice.worker.\(token)", qos: .userInitiated).async { [weak self] in
            defer { try? reader.close() }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                // A single POSIX read returns the bytes currently in the pipe.
                // FileHandle.read(upToCount:) can wait to fill the requested size.
                let size = buffer.withUnsafeMutableBytes { read(reader.fileDescriptor, $0.baseAddress, $0.count) }
                if size < 0 && errno == EINTR { continue }
                let data = size > 0 ? Data(buffer.prefix(size)) : Data()
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.generation == token else { return }
                    if data.isEmpty { self.fail("Local engine stopped. Try again to restart it."); return }
                    self.bytes.append(data); self.consume()
                }
                if data.isEmpty { break }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self = self, self.generation == token, !self.isReady else { return }
            self.fail("Loading the local model timed out.")
        }
    }
    func request(_ payload: [String: Any], timeout: Double = 120, completion: @escaping (Result<String, Error>) -> Void) {
        guard ready else { completion(.failure(VoiceError("Local engine is not ready yet."))); return }
        if pending != nil {
            guard queued.count < 4 else { completion(.failure(VoiceError("Local processing queue is full."))); return }
            queued.append((payload, timeout, completion)); return
        }
        let id = UUID().uuidString; var body = payload; body["id"] = id
        do {
            var data = try JSONSerialization.data(withJSONObject: body); data.append(10)
            guard let input = input else { throw VoiceError("Local engine input is unavailable.") }
            pending = (id, completion); try input.write(contentsOf: data)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard self?.pending?.id == id else { return }
                self?.fail("Local processing timed out. Original text is kept when available.")
            }
        } catch { fail(error.localizedDescription) }
    }
    private func consume() {
        let token = generation
        while let end = bytes.firstIndex(of: 10) {
            let line = bytes[..<end]; bytes.removeSubrange(...end)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if value["ready"] as? Bool == true {
                isReady = true; let callbacks = warmCallbacks; warmCallbacks.removeAll(); callbacks.forEach { $0(.success(())) }
            } else if let id = value["id"] as? String, id == pending?.id {
                let callback = pending?.completion; pending = nil
                if let error = value["error"] as? String { callback?(.failure(VoiceError(error))) }
                else { callback?(.success(value["text"] as? String ?? "")) }
                guard generation == token else { return }
                if pending == nil, !queued.isEmpty {
                    let next = queued.removeFirst(); request(next.payload, timeout: next.timeout, completion: next.completion)
                }
            } else if let error = value["error"] as? String { fail(error) }
            guard generation == token else { return }
        }
        if bytes.count > 8_000_000 { fail("Unexpected local engine response.") }
    }
    private func fail(_ message: String) { stop(error: VoiceError(message)) }
    func cancelPending() {
        let waiting = queued; queued.removeAll()
        if let current = pending {
            // Retain the ID until the worker acknowledges cancellation, so its
            // late result can never become the next dictation's response.
            pending = (current.id, { _ in })
            do {
                var data = try JSONSerialization.data(withJSONObject: ["cancel": current.id]); data.append(10)
                guard let input = input else { throw VoiceError("Local engine input is unavailable.") }
                try input.write(contentsOf: data)
            } catch { stop() }
            current.completion(.failure(VoiceError("Dictation cancelled.")))
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard self?.pending?.id == current.id else { return }
                self?.fail("The engine did not acknowledge cancellation. Try again to reload it.")
            }
        }
        waiting.forEach { $0.completion(.failure(VoiceError("Dictation cancelled."))) }
    }
    func stop(error: Error = VoiceError("Local processing cancelled.")) {
        generation = UUID(); isReady = false; loadedModel = nil
        try? input?.close(); input = nil
        if let child = process, child.isRunning {
            child.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
            }
        }
        process = nil; output = nil; bytes.removeAll()
        let callbacks = warmCallbacks; warmCallbacks.removeAll()
        let cancelledQueue = queued; queued.removeAll()
        let callback = pending?.completion; pending = nil
        callbacks.forEach { $0(.failure(error)) }; callback?(.failure(error)); cancelledQueue.forEach { $0.completion(.failure(error)) }
    }
}
