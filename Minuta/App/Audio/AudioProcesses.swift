import CoreAudio
import Foundation

/// Which processes Core Audio knows about and whether they are using the mic or speakers.
/// Used by the debug menu now and by meeting detection in M4.
nonisolated struct AudioProcess: Sendable, Identifiable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningInput: Bool
    let isRunningOutput: Bool

    static func all() throws -> [AudioProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        return try CA.getArray(system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self).map { obj in
            AudioProcess(
                id: obj,
                pid: (try? CA.get(obj, kAudioProcessPropertyPID, default: pid_t(-1))) ?? -1,
                bundleID: (try? CA.getString(obj, kAudioProcessPropertyBundleID)) ?? "",
                isRunningInput: ((try? CA.get(obj, kAudioProcessPropertyIsRunningInput, default: UInt32(0))) ?? 0) != 0,
                isRunningOutput: ((try? CA.get(obj, kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0) != 0
            )
        }
    }
}
