import Foundation

/// Signal #10: Fires when user appears to cut off the other person mid-thought.
/// Detected when a short "Them" utterance (<5 words) is immediately followed
/// by a "You" utterance, suggesting they weren't finished.
struct InterruptionSignal: SignalMonitor {
    let nudgeType: NudgeType = .interruption

    /// Max words in "Them" utterance to consider it a cut-off.
    var cutoffWordThreshold: Int = 5
    /// How many interruptions in a window before nudging.
    var interruptionThreshold: Int = 2
    /// Rolling window to count interruptions (seconds).
    var windowSeconds: TimeInterval = 180
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 120

    private var lastFired: TimeInterval = -.infinity

    mutating func evaluate(utterances: [Utterance], elapsed: TimeInterval, context: PreCallContext) -> Nudge? {
        guard elapsed - lastFired >= cooldown else { return nil }
        guard utterances.count >= 3 else { return nil }

        let windowStart = elapsed - windowSeconds
        var interruptionCount = 0

        // Walk through utterances looking for the pattern:
        // "Them" says something short → immediately "You" starts talking
        for i in 1..<utterances.count {
            let prev = utterances[i - 1]
            let curr = utterances[i]

            guard prev.t >= windowStart else { continue }

            // Pattern: Them said something short, then You jumped in
            if !prev.isYou && prev.speaker != "Meeting" && curr.isYou {
                let prevWords = prev.text.split(separator: " ").count
                let gap = curr.t - prev.t
                // Short reply + quick takeover = likely interruption
                if prevWords <= cutoffWordThreshold && gap < 3.0 {
                    interruptionCount += 1
                }
            }
        }

        guard interruptionCount >= interruptionThreshold else { return nil }

        lastFired = elapsed
        return Nudge(
            id: UUID(),
            type: .interruption,
            text: "Let them finish",
            urgency: .high,
            timestamp: elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
    }
}
