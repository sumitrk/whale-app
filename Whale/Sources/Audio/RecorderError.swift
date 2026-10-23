import Foundation

enum RecorderError: LocalizedError {
    case notRecording
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case audioDeviceStartFailed(OSStatus)
    case inputDeviceUnavailable(String)
    case captureSessionSetupFailed(String)
    case noAudioCaptured

    var errorDescription: String? {
        switch self {
        case .notRecording:                          return "Not currently recording"
        case .tapCreationFailed(let s):              return "Failed to create audio tap (err \(s))"
        case .aggregateDeviceCreationFailed(let s):  return "Failed to create aggregate device (err \(s))"
        case .ioProcCreationFailed(let s):           return "Failed to create IOProc (err \(s))"
        case .audioDeviceStartFailed(let s):         return "Failed to start audio device (err \(s))"
        case .inputDeviceUnavailable(let reason):    return reason
        case .captureSessionSetupFailed(let reason): return "Failed to configure microphone capture: \(reason)"
        case .noAudioCaptured:                       return "No audio was captured"
        }
    }
}
