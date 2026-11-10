// This harness compiles the exact production stop method, injected by the
// runner. Foundation fakes exercise closure typing and shutdown ordering;
// they do not emulate or validate AVFoundation or ScreenCaptureKit APIs.
import Foundation

final class CaptureEventLog {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ event: String) { lock.lock(); entries.append(event); lock.unlock() }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return entries }
}
final class CaptureFakeInput {
    let log: CaptureEventLog
    init(_ log: CaptureEventLog) { self.log = log }
    func removeTap(onBus: Int) { log.append("remove-tap") }
}
final class CaptureFakeEngine {
    let inputNode: CaptureFakeInput
    let log: CaptureEventLog
    init(_ log: CaptureEventLog) { self.log = log; inputNode = CaptureFakeInput(log) }
    func stop() { log.append("engine-stop") }
}
final class CaptureFakeStream {
    let log: CaptureEventLog
    var beforeReturn: (() -> Void)?
    init(_ log: CaptureEventLog) { self.log = log }
    func stopCapture() async throws {
        log.append("producer-stop-start")
        try await Task.sleep(nanoseconds: 30_000_000)
        beforeReturn?()
        log.append("producer-stop-end")
    }
}
struct CaptureFlushError: Error {}
final class CaptureFakeJournal {
    let log: CaptureEventLog
    let fail: Bool
    init(_ log: CaptureEventLog, fail: Bool) { self.log = log; self.fail = fail }
    func flush() throws {
        log.append("flush")
        if fail { throw CaptureFlushError() }
    }
}
final class CaptureStopSubject {
    let queue = DispatchQueue(label: "capture-stop-regression")
    var token = UUID()
    var stopCallbacks: [(Result<Void, Error>) -> Void] = []
    var stopping = false
    var engine: CaptureFakeEngine?
    var stream: CaptureFakeStream?
    var running = true
    var journal: CaptureFakeJournal?
    var converters: [String: Int] = [:]
    var activeStream: CaptureFakeStream?

    // PRODUCTION_STOP_METHOD
}

@main enum CaptureStopTests {
    @MainActor static func main() async {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !value() { fatalError(message) }
        }
        for shouldFail in [false, true] {
            let log = CaptureEventLog()
            let subject = CaptureStopSubject()
            let stream = CaptureFakeStream(log)
            subject.engine = CaptureFakeEngine(log)
            subject.stream = stream; subject.activeStream = stream
            subject.journal = CaptureFakeJournal(log, fail: shouldFail)
            subject.converters = ["input": 1]
            stream.beforeReturn = {
                subject.queue.async { log.append("last-chunk") }
            }
            let originalToken = subject.token
            var callbackResults: [Bool] = []
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let callback: (Result<Void, Error>) -> Void = { result in
                    log.append("callback")
                    switch result {
                    case .success: callbackResults.append(true)
                    case .failure(let error):
                        check(error is CaptureFlushError, "Flush error type is preserved")
                        callbackResults.append(false)
                    }
                    if callbackResults.count == 2 { continuation.resume() }
                }
                subject.stop(completion: callback)
                subject.stop(completion: callback)
            }
            check(subject.token != originalToken, "Stop invalidates the capture token")
            check(callbackResults == [!shouldFail, !shouldFail], "Concurrent stop callers receive exactly one matching result")
            let events = log.events
            check(events.filter { $0 == "producer-stop-start" }.count == 1, "Stop coalesces one producer shutdown")
            check(events.filter { $0 == "remove-tap" }.count == 1, "Microphone tap removed once")
            check(events.filter { $0 == "engine-stop" }.count == 1, "Microphone engine stopped once")
            check(events.filter { $0 == "flush" }.count == 1, "Journal flushed once")
            check(events.firstIndex(of: "producer-stop-end")! < events.firstIndex(of: "flush")!, "Producer finishes before journal flush")
            check(events.firstIndex(of: "last-chunk")! < events.firstIndex(of: "flush")!, "Pending producer work drains before flush")
            check(events.firstIndex(of: "flush")! < events.firstIndex(of: "callback")!, "Callbacks follow journal flush")
            check(!subject.running && !subject.stopping, "Capture and stopping flags reset")
            check(subject.engine == nil && subject.stream == nil && subject.activeStream == nil, "Audio producers released")
            check(subject.journal == nil && subject.converters.isEmpty, "Queue resources released after successful or failed flush")
            check(subject.stopCallbacks.isEmpty, "Completed callback list cleared")
            let subsequent: Result<Void, Error> = await withCheckedContinuation { continuation in
                subject.stop { continuation.resume(returning: $0) }
            }
            if case .failure = subsequent { fatalError("Stopping again without a journal must succeed") }
            check(log.events.filter { $0 == "callback" }.count == 2, "Old callbacks are not replayed by a later stop")
        }
        let empty = CaptureStopSubject()
        let emptyResult: Result<Void, Error> = await withCheckedContinuation { continuation in
            empty.stop { continuation.resume(returning: $0) }
        }
        if case .failure = emptyResult { fatalError("An absent journal is a successful stop") }
        check(!empty.running && !empty.stopping && empty.stopCallbacks.isEmpty, "Empty capture completes shutdown")
        print("Passed \(checks) checks for the production capture-stop method with simulated devices.")
    }
}
