import Foundation

/// Signal #13: Fires when the user dominates the conversation over a rolling
/// window — not one long monologue (TalkTime catches that) but many medium
/// turns that keep filling the other person's openings.
///
/// Derived from real coaching notes: "you talked too much in the back half…
/// once Eric gave you an opening, you kept filling it with your own thesis."
/// Continuous-floor-time never fired on that meeting; word share does.
struct VoiceShareSignal: SignalMonitor {
    let nudgeType: NudgeType = .voiceShare

    /// Rolling window measured (seconds).
    var windowSeconds: TimeInterval = 300
    /// Your share of the words in the window that triggers the nudge.
    var shareThreshold: Double = 0.70
    /// Minimum words spoken in the window before judging (avoid tiny samples).
    var minWindowWords: Int = 150
    /// Let the meeting warm up first.
    var warmupSeconds: TimeInterval = 300
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 240

    private var lastFired: TimeInterval = -.infinity

    mutating func evaluate(_ input: SignalInput) -> Nudge? {
        guard input.speakerLabelsReliable else { return nil }
        guard input.elapsed >= warmupSeconds else { return nil }
        guard input.elapsed - lastFired >= cooldown else { return nil }

        let windowStart = input.elapsed - windowSeconds
        var youWords = 0
        var themWords = 0
        for turn in input.turns.reversed() {
            if turn.endT < windowStart { break }
            if turn.isYou {
                youWords += turn.wordCount
            } else if turn.speaker != "Meeting" {
                themWords += turn.wordCount
            }
        }

        let total = youWords + themWords
        guard total >= minWindowWords else { return nil }
        let share = Double(youWords) / Double(total)
        guard share >= shareThreshold else { return nil }

        lastFired = input.elapsed
        return Nudge(
            id: UUID(),
            type: .voiceShare,
            text: "You've had the floor — hand it back",
            urgency: .med,
            timestamp: input.elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
    }
}
