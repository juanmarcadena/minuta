import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let what: String
    let status: OSStatus
    var errorDescription: String? { "\(what) failed (OSStatus \(status))" }
}

/// Thin typed access to AudioObject properties.
nonisolated enum CA {
    static func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
        guard status == noErr else { throw CoreAudioError(what: what(), status: status) }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) throws -> T {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var out = value
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &out), "get '\(fourCC(selector))'")
        return out
    }

    static func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, of: T.Type) throws -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size), "size '\(fourCC(selector))'")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer), "get '\(fourCC(selector))'")
        return Array(UnsafeBufferPointer(start: buffer.bindMemory(to: T.self, capacity: count), count: count))
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString>.stride)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "get '\(fourCC(selector))'")
        return value?.takeRetainedValue() as String? ?? ""
    }

    /// The Core Audio process object for a PID (e.g. our own, to exclude it from a tap).
    static func processObject(pid: pid_t) throws -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                             UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object), "translate PID")
        return object
    }

    static func defaultOutputDeviceUID() throws -> String {
        let device: AudioObjectID = try get(AudioObjectID(kAudioObjectSystemObject),
                                            kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
        return try getString(device, kAudioDevicePropertyDeviceUID)
    }

    static func fourCC(_ v: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .macOSRoman) ?? "\(v)"
    }

    static func hostSeconds(_ hostTime: UInt64) -> Double {
        Double(AudioConvertHostTimeToNanos(hostTime)) / 1e9
    }
}
