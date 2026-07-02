import Foundation

/// Signal #5: Fires when user stacks 3+ questions in a single speaking turn
/// without letting the other person respond.
struct StackedQuestionsSignal: SignalMonitor {
    let nudgeType: NudgeType = .stackedQuestions

    /// How many questions in one turn triggers the nudge.
    var questionThreshold: Int = 3
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 60

    private var lastFired: TimeInterval = -.infinity
    /// Turns that already produced a nudge — one nudge per turn, even if the
    /// turn keeps growing past the threshold.
    private var firedTurnIDs: Set<UUID> = []

    mutating func evaluate(_ input: SignalInput) -> Nudge? {
        guard input.elapsed - lastFired >= cooldown else { return nil }
        guard let turn = input.turns.last, turn.isYou else { return nil }
        guard !firedTurnIDs.contains(turn.id) else { return nil }

        let questionCount = TextAnalysis.questionCount(turn.text)
        guard questionCount >= questionThreshold else { return nil }

        lastFired = input.elapsed
        firedTurnIDs.insert(turn.id)
        return Nudge(
            id: UUID(),
            type: .stackedQuestions,
            text: "One question at a time",
            urgency: .med,
            timestamp: input.elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
        firedTurnIDs = []
    }
}
