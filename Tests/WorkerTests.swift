import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@main enum WorkerTests {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let worker = LocalWorker(), binary = URL(fileURLWithPath: CommandLine.arguments[1]), model = URL(fileURLWithPath: CommandLine.arguments[2])
        var count = 0
        func check(_ condition: Bool, _ message: String) { count += 1; if !condition { fatalError(message) } }
        func spin(_ done: () -> Bool) {
            let deadline = Date().addingTimeInterval(20)
            while !done() && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
            check(done(), "Lifecycle timed out")
        }
        var loaded = false
        worker.warm(executable: binary, model: model) { result in
            if case .failure(let error) = result { fatalError(error.localizedDescription) }; loaded = true
        }
        spin { loaded }; check(worker.ready, "Warm ready")
        var replies = [String]()
        for value in ["one", "two", "three"] {
            worker.request(["text": value]) { if case .success(let text) = $0 { replies.append(text) } else { fatalError("Queued failure") } }
        }
        spin { replies.count == 3 }; check(replies == ["one", "two", "three"], "FIFO requests")
        var pid = ""
        worker.request(["pid": true]) { if case .success(let value) = $0 { pid = value } }
        spin { !pid.isEmpty }
        for cycle in 0..<100 {
            var cancelled = false, recovered = "", queuedCancelled = false
            worker.request(["slow": true]) { result in
                if case .success = result { fatalError("Cancelled text escaped") }; cancelled = true
            }
            worker.request(["text": "abandoned queued text"]) { result in
                if case .success = result { fatalError("Cancelled queued text escaped") }; queuedCancelled = true
            }
            worker.cancelPending()
            check(cancelled && queuedCancelled, "Cancellation completes both callers once")
            check(worker.ready, "Cancellation keeps model loaded")
            worker.request(["text": "fresh-\(cycle)"]) { if case .success(let value) = $0 { recovered = value } else { fatalError("Restart failed") } }
            spin { !recovered.isEmpty }; check(recovered == "fresh-\(cycle)", "No stale response after cancellation")
        }
        var nextPID = ""
        worker.request(["pid": true]) { if case .success(let value) = $0 { nextPID = value } }
        spin { !nextPID.isEmpty }; check(nextPID == pid, "100 cancellations reuse one model process")
        var timedOut = false
        worker.request(["slow": true], timeout: 0.02) { if case .failure = $0 { timedOut = true } }
        spin { timedOut }; check(!worker.ready, "Timeout invalidates engine")
        for _ in 0..<20 {
            loaded = false
            worker.warm(executable: binary, model: model) { if case .success = $0 { loaded = true } }
            spin { loaded }; check(worker.ready, "Mode-on reload succeeds")
            worker.stop(); check(!worker.ready, "Mode-off releases process")
        }
        // Stop during model loading, then immediately load again. Old ready/EOF
        // events must not fail or complete the new generation's callback.
        let slowModel = model.appendingPathExtension("slow")
        try! "0.15".write(to: slowModel, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: slowModel) }
        for _ in 0..<20 {
            var oldCount = 0; loaded = false
            worker.warm(executable: binary, model: slowModel) { _ in oldCount += 1 }
            worker.stop()
            worker.warm(executable: binary, model: model) { if case .success = $0 { loaded = true } }
            spin { loaded }; check(oldCount == 1, "Old load callback completed exactly once")
            check(worker.ready, "Old process termination cannot stop new model")
            worker.stop()
        }
        print("Passed \(count) worker lifecycle checks, including 100 cancel/restart cycles.")
    }
}
