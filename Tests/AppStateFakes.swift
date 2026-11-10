// Platform stand-ins only. Tests compile the real AppState.swift unchanged apart
// from its imports, and exercise its callbacks, session IDs and mode transitions.
import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
final class TestApplication {
    enum Policy { case regular, accessory }
    func setActivationPolicy(_ policy: Policy) {}
}
let NSApp = TestApplication()
final class NSRunningApplication {
    let processIdentifier: Int32
    init(processIdentifier: Int32) { self.processIdentifier = processIdentifier }
}
final class NSWorkspace {
    static let shared = NSWorkspace()
    static let willSleepNotification = Notification.Name("sleep")
    static let sessionDidResignActiveNotification = Notification.Name("logout")
    static let didActivateApplicationNotification = Notification.Name("activate")
    let notificationCenter = NotificationCenter()
    var frontmostApplication: NSRunningApplication? = NSRunningApplication(processIdentifier: 777)
    func open(_ url: URL) {}
    func activateFileViewerSelecting(_ urls: [URL]) {}
}
final class NSSound {
    struct Name { init(_ name: String) {} }
    init?(named: Name) {}
    func play() {}
}
enum AVCaptureDevice {
    enum Status { case authorized, notDetermined }
    enum Media { case audio }
    static func authorizationStatus(for: Media) -> Status { .authorized }
    static func requestAccess(for: Media, completion: @escaping (Bool) -> Void) { completion(true) }
}
typealias CFDictionary = [String: Bool]
struct AXOption { func takeUnretainedValue() -> String { "prompt" } }
let kAXTrustedCheckOptionPrompt = AXOption()
func AXIsProcessTrusted() -> Bool { true }
func AXIsProcessTrustedWithOptions(_ options: CFDictionary) -> Bool { true }
func CGRequestListenEventAccess() -> Bool { true }
final class HotkeyMonitor {
    static var latest: HotkeyMonitor!
    var shortcut = Shortcut.rightOption
    var onAction: ((KeyAction) -> Void)?
    var onEscape: (() -> Void)?
    var onTyping: (() -> Void)?
    var onLost: (() -> Void)?
    init() { Self.latest = self }
    func start() -> Bool { true }
    func resetHold() {}
    func stop() {}
}
struct AudioStatus {
    let samples: Int; let lastVoice: Int; let level: Float
    var seconds: Double { Double(samples) / 16000 }
}
final class AudioRecorder {
    static var latest: AudioRecorder!
    var status = AudioStatus(samples: 16000, lastVoice: 16000, level: 0.3)
    var error: String?
    var starts = 0
    var startFails = false
    init() { Self.latest = self }
    func start() throws {
        if startFails { throw VoiceError("Simulated microphone failure") }
        starts += 1; status = AudioStatus(samples: 16000, lastVoice: 16000, level: 0.3)
    }
    func stop() {}
    func clear() {}
    func write(from: Int, through: Int, to url: URL) throws { try Data([0,0,0,0]).write(to: url) }
}
final class LocalWorker {
    static var all = [LocalWorker]()
    var ready = false
    var pending = [(Result<String, Error>) -> Void]()
    var requests = [[String: Any]]()
    var late = [(Result<String, Error>) -> Void]()
    var delayedWarm = false
    var warming = [(Result<Void, Error>) -> Void]()
    init() { Self.all.append(self) }
    func warm(executable: URL?, model: URL, completion: @escaping (Result<Void, Error>) -> Void = { _ in }) {
        if delayedWarm { warming.append(completion) } else { ready = true; completion(.success(())) }
    }
    func request(_ payload: [String: Any], timeout: Double = 120, completion: @escaping (Result<String, Error>) -> Void) {
        if payload["prepare"] as? Bool == true { completion(.success("")) } else { requests.append(payload); pending.append(completion) }
    }
    func reply(_ text: String) { let callback = pending.removeFirst(); callback(.success(text)) }
    func cancelPending() {
        let callbacks = pending; pending.removeAll(); late += callbacks
        callbacks.forEach { $0(.failure(VoiceError("cancelled"))) }
    }
    func sendLateReply() { let callbacks = late; late.removeAll(); callbacks.forEach { $0(.success("STALE TEXT")) } }
    func stop() {
        ready = false; cancelPending()
        let callbacks = warming; warming.removeAll(); callbacks.forEach { $0(.failure(VoiceError("stopped"))) }
    }
}
struct PasteTarget {}
enum PasteService {
    static var onReceiptChange: (() -> Void)?
    static var canRestore = false
    static var lastFailure = "The field changed; your text is saved."
    static var validTarget = true
    static var document = ""
    static var pastes = 0
    static func clearReceipt() { canRestore = false; onReceiptChange?() }
    static func capture() -> PasteTarget? { validTarget ? PasteTarget() : nil }
    static func copy(_ text: String) -> Bool { true }
    static func insert(_ text: String, into target: PasteTarget?, restoreClipboard: Bool) -> Bool {
        guard target != nil, validTarget else { return false }
        document += InsertionSpacing.prepare(text, before: document, after: ""); pastes += 1; return true
    }
    static func restore(original: String? = nil, restoreClipboard: Bool, completion: (Bool, String) -> Void) { completion(false,"Not available in fake editor") }
}
enum AppPaths {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("localvoice-state-" + UUID().uuidString)
    static var engine: URL? { root.appendingPathComponent("speech") }
    static var editor: URL? { root.appendingPathComponent("editor") }
    static var editorModel: URL { root.appendingPathComponent("model") }
    static var hasEditorModel: Bool { true }
    static func hasModel(_ model: SpeechModel) -> Bool { true }
    static func modelURL(_ model: SpeechModel) -> URL { root.appendingPathComponent(model.filename) }
    static func clearAbandonedSessions() {}
    static func newSession() throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); return folder
    }
}
final class ModelDownload {
    init(model: SpeechModel, progress: @escaping (Double, String) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {}
    func start() {}
    func cancel() {}
}
