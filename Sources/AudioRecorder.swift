import AVFoundation
struct AudioStatus {
    let samples: Int
    let lastVoice: Int
    let level: Float
    var seconds: Double { Double(samples) / 16000 }
}
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var lastVoice = 0
    private var meter: Float = 0
    private var active = false
    private var installedTap = false
    private var conversionError: String?
    private var generation = UUID()
    var status: AudioStatus { lock.lock(); defer { lock.unlock() }; return AudioStatus(samples: samples.count, lastVoice: lastVoice, level: meter) }
    var error: String? { lock.lock(); defer { lock.unlock() }; return conversionError }
    func start() throws {
        stop()
        let input = engine.inputNode, source = engine.inputNode.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else { throw VoiceError("No usable microphone. Check your input device.") }
        let token = UUID()
        lock.lock(); generation = token; samples.removeAll(keepingCapacity: true); lastVoice = 0; meter = 0; conversionError = nil; active = true; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: source) { [weak self] buffer, _ in
            guard let self = self else { return }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / source.sampleRate) + 32)
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false, error: NSError?
            let result = converter.convert(to: converted, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.active, self.generation == token else { return }
            guard result != .error, error == nil, let values = converted.floatChannelData?[0] else { self.conversionError = "Microphone conversion failed. Try another input device."; return }
            let count = Int(converted.frameLength); guard count > 0 else { return }
            var energy: Float = 0
            for i in 0..<count { energy += values[i] * values[i] }
            let rms = sqrt(energy / Float(count))
            self.samples.append(contentsOf: UnsafeBufferPointer(start: values, count: count))
            if rms > 0.0008 { self.lastVoice = self.samples.count }
            self.meter = min(1, max(0, (20 * log10(max(rms, 0.00001)) + 55) / 55))
        }
        installedTap = true
        do { engine.prepare(); try engine.start() } catch { stop(); throw error }
    }
    func write(from start: Int, through end: Int, to url: URL) throws {
        lock.lock()
        let lo = max(0, min(start, samples.count)), hi = max(lo, min(end, samples.count))
        let data = samples.withUnsafeBufferPointer { buffer -> Data in
            guard hi > lo, let base = buffer.baseAddress else { return Data() }
            return Data(bytes: base.advanced(by: lo), count: (hi - lo) * MemoryLayout<Float>.size)
        }
        lock.unlock(); try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func stop() {
        lock.lock(); active = false; generation = UUID(); lock.unlock()
        if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }; engine.stop()
    }
    func clear() { stop(); lock.lock(); samples.removeAll(); lastVoice = 0; meter = 0; lock.unlock() }
}
