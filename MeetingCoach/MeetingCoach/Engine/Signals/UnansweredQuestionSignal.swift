import Foundation

/// Signal #9: Fires when the other person asked a question but the user
/// talked for 3+ turns without addressing it.
struct UnansweredQuestionSignal: SignalMonitor {
    let nudgeType: NudgeType = .unansweredQuestion

    /// How many "You" turns after their question before nudging.
    var turnsBeforeNudge: Int = 3
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 90

    private var lastFired: TimeInterval = -.infinity
    private var pendingQuestion: String?
    private var turnsSinceQuestion: Int = 0

    mutating func evaluate(utterances: [Utterance], elapsed: TimeInterval, context: PreCallContext) -> Nudge? {
        guard elapsed - lastFired >= cooldown else { return nil }
        guard utterances.count >= 2 else { return nil }

        // Walk backwards to find the pattern:
        // "Them" asks a question, then N consecutive "You" turns follow
        var youTurnCount = 0
        var foundTheirQuestion = false

        for utt in utterances.reversed() {
            if utt.isYou {
                youTurnCount += 1
            } else if utt.speaker != "Meeting" {
                // "Them" utterance — check if it's a question
                if Self.isQuestion(utt.text) {
                    foundTheirQuestion = true
                }
                break
            }
        }

        guard foundTheirQuestion, youTurnCount >= turnsBeforeNudge else { return nil }

        lastFired = elapsed
        return Nudge(
            id: UUID(),
            type: .unansweredQuestion,
            text: "They asked a question — answer it",
            urgency: .high,
            timestamp: elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
        pendingQuestion = nil
        turnsSinceQuestion = 0
    }

    private static let questionStarters: Set<String> = [
        "what", "how", "why", "when", "where", "who", "which",
        "could", "would", "should", "can", "do", "does", "did",
        "is", "are", "was", "were", "have", "has", "will",
    ]

    static func isQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { return true }
        let lower = trimmed.lowercased()
        let sentences = lower.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        for sentence in sentences {
            let words = sentence.trimmingCharacters(in: .whitespaces).split(separator: " ")
            if let first = words.first, questionStarters.contains(String(first)) {
                return true
            }
        }
        return false
    }
}
