import Foundation

/// Signal #7: Fires when the other person's replies are getting shorter,
/// indicating disengagement, frustration, or intimidation.
struct GoingQuietSignal: SignalMonitor {
    let nudgeType: NudgeType = .goingQuiet

    /// Number of recent "Them" turns to check.
    var recentTurnCount: Int = 5
    /// Average word count at or below this triggers the nudge.
    var shortReplyThreshold: Double = 5
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 180
    /// Minimum elapsed time before this can fire (let the meeting warm up).
    var warmupSeconds: TimeInterval = 180

    private var lastFired: TimeInterval = -.infinity

    mutating func evaluate(_ input: SignalInput) -> Nudge? {
        guard input.speakerLabelsReliable else { return nil }
        guard input.elapsed >= warmupSeconds else { return nil }
        guard input.elapsed - lastFired >= cooldown else { return nil }

        // Collect "Them" turns (real turns, not ASR fragments). Exclude pure
        // backchannels ("yeah", "okay") — those are them LISTENING while you
        // talk, not them replying briefly. Counting them as short replies
        // made every monologue of yours look like their disengagement.
        let themTurns = input.turns.filter {
            !$0.isYou && $0.speaker != "Meeting" && !YesManSignal.isAgreementOnly($0.text)
        }
        guard themTurns.count >= recentTurnCount + 3 else { return nil }

        let recent = themTurns.suffix(recentTurnCount)
        let avgWords = Double(recent.map(\.wordCount).reduce(0, +)) / Double(recent.count)
        guard avgWords <= shortReplyThreshold else { return nil }

        // Make sure they were talking more earlier (not just a quiet person)
        let earlier = themTurns.dropLast(recentTurnCount).suffix(recentTurnCount)
        guard earlier.count >= 3 else { return nil }
        let earlierAvg = Double(earlier.map(\.wordCount).reduce(0, +)) / Double(earlier.count)
        guard earlierAvg > shortReplyThreshold + 2 else { return nil }

        lastFired = input.elapsed
        return Nudge(
            id: UUID(),
            type: .goingQuiet,
            text: "They've gone quiet — ask what they think",
            urgency: .med,
            timestamp: input.elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
    }
}
