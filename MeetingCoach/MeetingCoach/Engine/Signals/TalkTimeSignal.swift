import Foundation

/// Signal #1: Fires when user holds the floor > threshold seconds continuously.
struct TalkTimeSignal: SignalMonitor {
    let nudgeType: NudgeType = .talkTime

    /// Continuous "You" speaking time before firing (seconds).
    var threshold: TimeInterval = 180
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 120

    private var lastFired: TimeInterval = -.infinity

    mutating func evaluate(utterances: [Utterance], elapsed: TimeInterval, context: PreCallContext) -> Nudge? {
        guard elapsed - lastFired >= cooldown else { return nil }
        guard !utterances.isEmpty else { return nil }

        // Walk backwards counting continuous "You" speaking time.
        var continuousTime: TimeInterval = 0
        var prevStart: TimeInterval = elapsed

        for utt in utterances.reversed() {
            guard utt.isYou else { break }
            let uttEnd = prevStart
            let uttStart = utt.t
            continuousTime += uttEnd - uttStart
            prevStart = uttStart
        }

        guard continuousTime >= threshold else { return nil }

        lastFired = elapsed
        return Nudge(
            id: UUID(),
            type: .talkTime,
            text: "You're still talking",
            urgency: .high,
            timestamp: elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
    }
}
