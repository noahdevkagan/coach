import Foundation

/// Signal #2: Fires when 5 min elapsed with no detected question from user.
struct MissingDiscoverySignal: SignalMonitor {
    let nudgeType: NudgeType = .missingDiscovery

    /// Window to look back for questions (seconds).
    var windowSeconds: TimeInterval = 300  // 5 minutes
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 300       // 5 minutes

    private var lastFired: TimeInterval = -.infinity

    mutating func evaluate(_ input: SignalInput) -> Nudge? {
        guard input.speakerLabelsReliable else { return nil }
        guard input.elapsed >= windowSeconds else { return nil }
        guard input.elapsed - lastFired >= cooldown else { return nil }

        // Only check "You" turns in the last window.
        let windowStart = input.elapsed - windowSeconds
        let hasQuestion = input.turns.reversed().contains { turn in
            guard turn.endT >= windowStart else { return false }
            return turn.isYou && TextAnalysis.isQuestion(turn.text)
        }
        guard !hasQuestion else { return nil }

        lastFired = input.elapsed
        return Nudge(
            id: UUID(),
            type: .missingDiscovery,
            text: "Ask them something",
            urgency: .med,
            timestamp: input.elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
    }
}
