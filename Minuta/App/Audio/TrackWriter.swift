import AVFoundation
import MinutaCore

/// Writes one track to disk as 16 kHz mono 16-bit CAF (what Whisper wants, ~115 MB per hour),
/// converting from whatever format the source delivers. Not real-time safe: call it from a
/// serial queue, never from inside a real-time audio callback.
nonisolated final class TrackWriter: @unchecked Sendable {
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let file: AVAudioFile
    private var converter: AVAudioConverter?
    private(set) var firstSampleHostSeconds: Double?
    private(set) var framesWritten: AVAudioFramePosition = 0
    private(set) var peak: Float = 0

    init(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) throws {
        if firstSampleHostSeconds == nil, hostTime != 0 { firstSampleHostSeconds = CA.hostSeconds(hostTime) }
        if let first = firstSampleHostSeconds, hostTime != 0 {
            let gap = TimelineGap.silence(elapsed: CA.hostSeconds(hostTime) - first, written: seconds)
            if gap > 0 { try writeSilence(seconds: min(gap, 600)) }
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
        }
        guard let converter else { return }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        if out.frameLength > 0 {
            if let data = out.floatChannelData?[0] {
                for i in 0..<Int(out.frameLength) { peak = max(peak, abs(data[i])) }
            }
            try file.write(from: out)
            framesWritten += AVAudioFramePosition(out.frameLength)
        }
    }

    var seconds: Double { Double(framesWritten) / Self.targetFormat.sampleRate }

    private func writeSilence(seconds: Double) throws {
        var remaining = AVAudioFrameCount(seconds * Self.targetFormat.sampleRate)
        while remaining > 0 {
            let n = min(remaining, 16_000)
            guard let zeros = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: n) else { return }
            zeros.frameLength = n
            if let data = zeros.floatChannelData?[0] { data.update(repeating: 0, count: Int(n)) }
            try file.write(from: zeros)
            framesWritten += AVAudioFramePosition(n)
            remaining -= n
        }
    }
}
