import AVFoundation

/// Records the default input (your side of the call) with AVAudioEngine. When the input device changes
/// mid-call (AirPods connect or disconnect), it moves to the new default mic and keeps writing
/// to the same file; the writer pads the gap so timestamps stay true.
nonisolated final class MicRecorder: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "minuta.mic", qos: .userInitiated)
    private var writer: TrackWriter?
    private var configObserver: NSObjectProtocol?
    private var stopped = true
    private(set) var lastError: Error?
    /// Times the mic moved to another device during this recording.
    private(set) var deviceChanges = 0

    var firstSampleHostSeconds: Double? { queue.sync { writer?.firstSampleHostSeconds } }
    var secondsWritten: Double { queue.sync { writer?.seconds ?? 0 } }
    var peak: Double { queue.sync { Double(writer?.peak ?? 0) } }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(writingTo url: URL) throws {
        writer = try TrackWriter(url: url)
        stopped = false
        try startEngine()
    }

    /// A fresh engine picks up the current default input device and its format.
    private func startEngine() throws {
        let engine = AVAudioEngine()
        self.engine = engine
        guard let writer else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let queue = queue
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            // Not the real-time thread; serialize with stop() so the file closes cleanly.
            let error: Error? = queue.sync {
                do { try writer.write(buffer, hostTime: time.hostTime); return nil } catch { return error }
            }
            if let error { self?.lastError = error }
        }
        engine.prepare()
        try engine.start()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restart(attempt: 0)
        }
    }

    private func tearDownEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// The device can take a moment to be ready after a switch, so retry a few times.
    private func restart(attempt: Int) {
        guard !stopped else { return }
        tearDownEngine()
        do {
            try startEngine()
            deviceChanges += 1
        } catch where attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.restart(attempt: attempt + 1) }
        } catch {
            lastError = error
        }
    }

    func stop() {
        stopped = true
        tearDownEngine()
        queue.sync { writer = nil }
    }
}
