import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Only audio outputs are registered. No screen pixels are read or saved.
final class MeetingCapture: NSObject, MeetingCapturing, SCStreamOutput, SCStreamDelegate {
    var onError: ((Error) -> Void)?
    var onLevel: ((Float, Float) -> Void)?
    private let queue = DispatchQueue(label: "localvoice.meeting.capture", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var stream: SCStream?
    private var journal: MeetingAudioJournal? // Access only on queue.
    private var converters: [MeetingTrack: AVAudioConverter] = [:]
    private var running = false
    private var epoch: Double = 0
    private var base: Double = 0
    private var levels: [MeetingTrack: Float] = [:]
    private var lastMeter: Double = 0
    private var token = UUID()
    private var stopping = false
    private var stopCallbacks: [(Result<Void, Error>) -> Void] = []
    private var queueGeneration = UUID()
    private var activeStream: SCStream?
    private var captureFailure: Error?
    func start(source: MeetingSource, folder: URL, offset: Double,
               onChunk: @escaping (MeetingChunk) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        guard engine == nil, stream == nil, !stopping else { completion(.failure(VoiceError("Audio capture is still stopping."))); return }
        let id = UUID(); token = id
        Task { @MainActor [self] in
            do {
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                    throw VoiceError("Allow Microphone access in Setup before starting a meeting.")
                }
                var candidate: SCStream?
                if source == .online {
                    // The OS requests permission only after the user chooses Start.
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard let display = content.displays.first else { throw VoiceError("No display is available for Mac audio capture.") }
                    let excluded = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                    let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                    let config = SCStreamConfiguration()
                    config.capturesAudio = true; config.excludesCurrentProcessAudio = true
                    config.sampleRate = 48000; config.channelCount = 1
                    config.width = 128; config.height = 128; config.queueDepth = 3
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                    config.showsCursor = false
                    let capture = SCStream(filter: filter, configuration: config, delegate: self)
                    try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                    candidate = capture
                }
                guard self.token == id else { completion(.failure(VoiceError("Meeting start cancelled."))); return }
                let mic = AVAudioEngine()
                // Use the actual input node's format (devices may change at start).
                let inputFormat = mic.inputNode.outputFormat(forBus: 0)
                guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw VoiceError("No usable microphone is selected in macOS Sound settings.") }
                self.queue.sync {
                    self.journal = MeetingAudioJournal(folder: folder) { chunk in DispatchQueue.main.async { onChunk(chunk) } }
                    self.converters = [:]; self.levels = [:]; self.epoch = ProcessInfo.processInfo.systemUptime; self.base = offset; self.running = true
                    self.queueGeneration = id; self.activeStream = candidate; self.captureFailure = nil
                }
                mic.inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, time in
                    guard let self = self, let copy = Self.copy(buffer) else { return }
                    let when = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : ProcessInfo.processInfo.systemUptime - Double(buffer.frameLength) / inputFormat.sampleRate
                    self.queue.async { self.receive(copy, track: .microphone, when: when, generation: id) }
                }
                self.engine = mic; self.stream = candidate
                mic.prepare(); try mic.start()
                if let candidate = candidate { try await candidate.startCapture() }
                guard self.token == id else { completion(.failure(VoiceError("Meeting start cancelled."))); return }
                if let failure = self.queue.sync(execute: { self.captureFailure }) { throw failure }
                completion(.success(()))
            } catch {
                self.stop { _ in completion(.failure(VoiceError("Could not start meeting audio: \(error.localizedDescription). For online meetings, allow Screen & System Audio Recording in Privacy & Security and reopen Voice."))) }
            }
        }
    }
    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        target.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(target.mutableAudioBufferList)
        for index in 0..<min(from.count, to.count) {
            guard let input = from[index].mData, let output = to[index].mData else { return nil }
            memcpy(output, input, Int(min(from[index].mDataByteSize, to[index].mDataByteSize)))
        }
        return target
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard stream === activeStream, type == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return }
        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) else { return }
                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                let now = ProcessInfo.processInfo.systemUptime
                let when = pts.isFinite && abs(pts - now) < 10 ? pts : now - Double(buffer.frameLength) / format.sampleRate
                self.receive(buffer, track: .computer, when: when, generation: self.queueGeneration)
            }
        } catch { fail(error) }
    }
    private func receive(_ buffer: AVAudioPCMBuffer, track: MeetingTrack, when: Double, generation: UUID) {
        guard running, generation == queueGeneration, let journal = journal else { return }
        do {
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else { return }
            if converters[track]?.inputFormat != buffer.format {
                guard let converter = AVAudioConverter(from: buffer.format, to: target) else { throw VoiceError("Meeting audio format could not be converted.") }
                converter.primeMethod = .none; converters[track] = converter
            }
            guard let converter = converters[track], let output = AVAudioPCMBuffer(pcmFormat: target,
                frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 64)) else { return }
            var fed = false, error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if fed { state.pointee = .noDataNow; return nil }; fed = true; state.pointee = .haveData; return buffer
            }
            guard status != .error, error == nil, let floats = output.floatChannelData?[0] else { throw error ?? VoiceError("Meeting audio conversion failed.") as NSError }
            let samples = Array(UnsafeBufferPointer(start: floats, count: Int(output.frameLength)))
            try journal.append(samples, track: track, start: base + max(0, when - epoch))
            let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, samples.count)))
            levels[track] = min(1, max(0, (20 * log10(max(rms, 0.00001)) + 55) / 55))
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastMeter > 0.1 {
                lastMeter = now; let mic = levels[.microphone] ?? 0, system = levels[.computer] ?? 0
                DispatchQueue.main.async { [weak self] in self?.onLevel?(mic, system) }
            }
        } catch { fail(error) }
    }
    private func fail(_ error: Error) {
        guard running else { return }; running = false; captureFailure = error
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in if self?.activeStream === stream { self?.fail(error) } }
    }
    func stop(completion: @escaping (Result<Void, Error>) -> Void) {
        token = UUID()
        stopCallbacks.append(completion)
        guard !stopping else { return }
        stopping = true
        if let engine = engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }; engine = nil
        let current = stream; stream = nil
        Task { @MainActor [self] in
            // Stop the producer before draining the serial queue and closing files.
            if let current = current { try? await current.stopCapture() }
            // Keep the capture alive until every queued sample and stop callback
            // has been handled. State below is confined to the capture queue.
            self.queue.async { [self] in
                self.running = false
                let result: Result<Void, Error>
                do {
                    try self.journal?.flush()
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
                self.journal = nil; self.converters = [:]; self.activeStream = nil
                DispatchQueue.main.async { [self] in
                    self.stopping = false
                    let callbacks = self.stopCallbacks; self.stopCallbacks = []
                    for callback in callbacks { callback(result) }
                }
            }
        }
    }
}
