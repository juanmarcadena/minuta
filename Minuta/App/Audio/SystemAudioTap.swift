import AVFoundation
import CoreAudio

/// Captures what the Mac plays (the other people in the call) with a Core Audio process tap,
/// following Apple's "Capturing system audio with Core Audio taps": tap → private aggregate
/// device → IO proc. macOS asks for "System Audio Recording" the first time it starts.
nonisolated final class SystemAudioTap: @unchecked Sendable {
    enum Target: Sendable {
        /// Everything the Mac plays except Minuta itself (manual recording with no call app).
        case allExceptSelf
        /// Only processes whose bundle ID starts with one of these (a call app and its helpers),
        /// so a YouTube video or Spotify in another app stays out of the transcript.
        case apps(bundlePrefixes: [String])
    }

    private var target: Target = .allExceptSelf
    private var tappedProcesses: Set<AudioObjectID> = []

    /// Core Audio process objects currently matching the target's bundle prefixes.
    static func processes(matching prefixes: [String]) -> Set<AudioObjectID> {
        let me = getpid()
        return Set(((try? AudioProcess.all()) ?? [])
            .filter { p in p.pid != me && prefixes.contains { p.bundleID.hasPrefix($0) } }
            .map(\.id))
    }

    private let queue = DispatchQueue(label: "minuta.tap", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var writer: TrackWriter?
    private(set) var lastError: Error?

    var firstSampleHostSeconds: Double? { queue.sync { writer?.firstSampleHostSeconds } }
    var secondsWritten: Double { queue.sync { writer?.seconds ?? 0 } }
    var peak: Double { queue.sync { Double(writer?.peak ?? 0) } }

    /// Listens for the default output device changing (AirPods in or out).
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var stopped = true
    /// Times the aggregate was rebuilt for a new output device during this recording.
    private(set) var deviceChanges = 0

    func start(target: Target, writingTo url: URL) throws {
        let description: CATapDescription
        switch target {
        case .allExceptSelf:
            let me = try CA.processObject(pid: getpid())
            description = CATapDescription(monoGlobalTapButExcludeProcesses: me == kAudioObjectUnknown ? [] : [me])
        case .apps(let prefixes):
            tappedProcesses = Self.processes(matching: prefixes)
            description = CATapDescription(monoMixdownOfProcesses: Array(tappedProcesses))
        }
        self.target = target
        description.name = "Minuta"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try CA.check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")
        do {
            writer = try TrackWriter(url: url)
            stopped = false
            try startAggregate()
            listenForOutputChanges()
        } catch {
            stop()
            throw error
        }
    }

    /// Aggregate device = the tap, clocked by the current output device. It has to be rebuilt
    /// when that device goes away, or the stream stops.
    private func startAggregate() throws {
        guard let writer else { return }
        let tapUID = try CA.getString(tapID, kAudioTapPropertyUID)
        let outputUID = try CA.defaultOutputDeviceUID()
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Minuta Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        try CA.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID), "create aggregate device")

        var format: AudioStreamBasicDescription = try CA.get(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        guard let avFormat = AVAudioFormat(streamDescription: &format) else {
            throw CoreAudioError(what: "read tap format", status: -1)
        }
        try CA.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, inputTime, _, _ in
            guard let self,
                  let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, bufferListNoCopy: input, deallocator: nil) else { return }
            do { try writer.write(buffer, hostTime: inputTime.pointee.mHostTime) } catch { self.lastError = error }
        }, "create IO proc")
        try CA.check(AudioDeviceStart(aggregateID, procID), "start aggregate device")
    }

    private func stopAggregate() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    private func listenForOutputChanges() {
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.rebuildAggregate(attempt: 0) }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block) == noErr {
            outputListener = block
        }
    }

    private func rebuildAggregate(attempt: Int) {
        guard !stopped, tapID != kAudioObjectUnknown else { return }
        stopAggregate()
        do {
            try startAggregate()
            deviceChanges += 1
        } catch where attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.rebuildAggregate(attempt: attempt + 1) }
        } catch {
            lastError = error
        }
    }

    /// Call apps start new helper processes mid-call (screen share, reconnect). Adds them to the tap.
    func refreshProcesses() {
        guard case .apps(let prefixes) = target, tapID != kAudioObjectUnknown else { return }
        let now = Self.processes(matching: prefixes)
        guard now != tappedProcesses, !now.isEmpty else { return }
        let description = CATapDescription(monoMixdownOfProcesses: Array(now))
        description.name = "Minuta"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var addr = CA.address(kAudioTapPropertyDescription)
        var ref = description
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.stride), $0)
        }
        if status == noErr { tappedProcesses = now }
    }

    func stop() {
        stopped = true
        if let outputListener {
            var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, outputListener)
        }
        outputListener = nil
        stopAggregate()
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        queue.sync { writer = nil }  // drains pending writes and closes the file
    }
}
