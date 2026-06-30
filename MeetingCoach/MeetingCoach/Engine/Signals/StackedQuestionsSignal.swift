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

    private static let questionStarters: Set<String> = [
        "what", "how", "why", "when", "where", "who", "which",
        "could", "would", "should", "can", "do", "does", "did",
        "is", "are", "was", "were", "have", "has", "will",
    ]

    mutating func evaluate(utterances: [Utterance], elapsed: TimeInterval, context: PreCallContext) -> Nudge? {
        guard elapsed - lastFired >= cooldown else { return nil }
        guard utterances.count >= 2 else { return nil }

        // Find the current speaking turn: consecutive "You" utterances at the end
        var turnUtterances: [Utterance] = []
        for utt in utterances.reversed() {
            guard utt.isYou else { break }
            turnUtterances.insert(utt, at: 0)
        }
        guard !turnUtterances.isEmpty else { return nil }

        // Combine the turn into one block of text
        let turnText = turnUtterances.map(\.text).joined(separator: " ")

        // Count questions in this turn
        let questionCount = Self.countQuestions(turnText)
        guard questionCount >= questionThreshold else { return nil }

        lastFired = elapsed
        return Nudge(
            id: UUID(),
            type: .stackedQuestions,
            text: "One question at a time",
            urgency: .med,
            timestamp: elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
    }

    // MARK: - Helpers

    static func countQuestions(_ text: String) -> Int {
        var count = 0
        // Split into sentence-like chunks
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let words = trimmed.lowercased().split(separator: " ")
            guard let first = words.first else { continue }
            if questionStarters.contains(String(first)) {
                count += 1
            }
        }
        // Also count question marks (catches questions the split above may miss)
        let qmarkCount = text.filter { $0 == "?" }.count
        return max(count, qmarkCount)
    }
}
