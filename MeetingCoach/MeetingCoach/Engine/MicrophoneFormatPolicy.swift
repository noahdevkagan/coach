import Foundation

/// AVAudioEngine raises an Objective-C exception (and aborts the process)
/// when a tap is installed with a zero-channel or otherwise invalid format.
/// Keep the validation independent of AVFoundation so the crash boundary can
/// be regression-tested without touching live audio hardware.
enum MicrophoneFormatPolicy {
    static func isUsable(sampleRate: Double, channelCount: UInt32) -> Bool {
        sampleRate.isFinite && sampleRate > 0 && channelCount > 0
    }
}
