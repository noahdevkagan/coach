import Foundation

enum TriggerReason: String, Sendable {
    case heartbeat
    case longPause = "long_pause"
    case speakerHandoff = "speaker_handoff"
}

struct Trigger: Sendable {
    let reason: TriggerReason
    let now: TimeInterval
    let window: [Utterance]
    let summary: String
}
