import Foundation

/// Signal #9: Fires when the other person asked a question and the user has
/// been talking at length without letting them re-engage.
struct UnansweredQuestionSignal: SignalMonitor {
    let nudgeType: NudgeType = .unansweredQuestion

    /// How many words the user talks after their question before nudging.
    /// (~60 words ≈ 25 seconds of monologue past their question.)
    var wordsBeforeNudge: Int = 60
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 90

    private var lastFired: TimeInterval = -.infinity
    /// One nudge per question — latch on the Them turn that asked it.
    private var nudgedQuestionIDs: Set<UUID> = []

    mutating func evaluate(_ input: SignalInput) -> Nudge? {
        guard input.speakerLabelsReliable else { return nil }
        guard input.elapsed - lastFired >= cooldown else { return nil }
        let turns = input.turns
        guard turns.count >= 2 else { return nil }

        // Pattern: last turn is You (still talking), the turn before is Them
        // asking a question, and the You turn is long.
        let youTurn = turns[turns.count - 1]
        let themTurn = turns[turns.count - 2]
        guard youTurn.isYou,
              !themTurn.isYou, themTurn.speaker != "Meeting",
              youTurn.wordCount >= wordsBeforeNudge,
              !nudgedQuestionIDs.contains(themTurn.id),
              TextAnalysis.isQuestion(themTurn.text)
        else { return nil }

        lastFired = input.elapsed
        nudgedQuestionIDs.insert(themTurn.id)
        return Nudge(
            id: UUID(),
            type: .unansweredQuestion,
            text: "They asked a question — answer it",
            urgency: .high,
            timestamp: input.elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
        nudgedQuestionIDs = []
    }
}
