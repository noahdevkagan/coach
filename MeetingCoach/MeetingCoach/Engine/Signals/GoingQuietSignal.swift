import Foundation

/// Signal #7: Fires when the other person's replies are getting shorter,
/// indicating disengagement, frustration, or intimidation.
struct GoingQuietSignal: SignalMonitor {
    let nudgeType: NudgeType = .goingQuiet

    /// Number of recent "Them" turns to check.
    var recentTurnCount: Int = 5
    /// Average word count below this triggers the nudge.
    var shortReplyThreshold: Int = 4
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 90
    /// Minimum elapsed time before this can fire (let the meeting warm up).
    var warmupSeconds: TimeInterval = 120

    private var lastFired: TimeInterval = -.infinity

    mutating func evaluate(utterances: [Utterance], elapsed: TimeInterval, context: PreCallContext) -> Nudge? {
        guard elapsed >= warmupSeconds else { return nil }
        guard elapsed - lastFired >= cooldown else { return nil }

        // Collect recent "Them" utterances
        let themUtterances = utterances.filter { !$0.isYou && $0.speaker != "Meeting" }
        guard themUtterances.count >= recentTurnCount else { return nil }

        let recentThem = Array(themUtterances.suffix(recentTurnCount))
        let avgWords = recentThem.map { $0.text.split(separator: " ").count }.reduce(0, +) / recentTurnCount

        guard avgWords <= shortReplyThreshold else { return nil }

        // Make sure they were talking more earlier (not just a quiet person)
        let earlierThem = Array(themUtterances.dropLast(recentTurnCount).suffix(recentTurnCount))
        guard earlierThem.count >= 3 else { return nil }
        let earlierAvg = earlierThem.map { $0.text.split(separator: " ").count }.reduce(0, +) / earlierThem.count
        guard earlierAvg > shortReplyThreshold + 2 else { return nil }

        lastFired = elapsed
        return Nudge(
            id: UUID(),
            type: .goingQuiet,
            text: "They've gone quiet — ask what they think",
            urgency: .med,
            timestamp: elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
    }
}
