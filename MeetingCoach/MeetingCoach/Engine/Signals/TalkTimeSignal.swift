import Foundation

/// Signal #1: Fires when user holds the floor > threshold seconds continuously.
struct TalkTimeSignal: SignalMonitor {
    let nudgeType: NudgeType = .talkTime

    /// Continuous "You" speaking time before firing (seconds).
    var threshold: TimeInterval = 60
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 60
    /// Max gap between utterances before the streak breaks (seconds).
    var maxGap: TimeInterval = 10

    private var lastFired: TimeInterval = -.infinity

    mutating func evaluate(utterances: [Utterance], elapsed: TimeInterval, context: PreCallContext) -> Nudge? {
        guard elapsed - lastFired >= cooldown else { return nil }
        guard !utterances.isEmpty else { return nil }

        // Walk backwards through utterances counting continuous "You" speaking time.
        // Break on: non-"You" speaker, or gap > maxGap between consecutive utterances.
        var streakStart: TimeInterval = elapsed
        var prevTime: TimeInterval = elapsed

        for utt in utterances.reversed() {
            guard utt.isYou else { break }
            // If there's a big silence gap, the streak is broken
            if prevTime - utt.t > maxGap {
                break
            }
            streakStart = utt.t
            prevTime = utt.t
        }

        let continuousTime = elapsed - streakStart
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
