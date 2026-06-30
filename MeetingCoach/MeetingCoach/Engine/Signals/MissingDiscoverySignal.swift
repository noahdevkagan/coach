import Foundation

/// Signal #2: Fires when 10 min elapsed with no detected question from user.
struct MissingDiscoverySignal: SignalMonitor {
    let nudgeType: NudgeType = .missingDiscovery

    /// Window to look back for questions (seconds).
    var windowSeconds: TimeInterval = 300  // 5 minutes
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 300       // 5 minutes

    private var lastFired: TimeInterval = -.infinity

    /// Regex patterns that indicate a question.
    private static let questionStarters = [
        "what", "how", "why", "when", "where", "who", "which",
        "could", "would", "should", "can", "do", "does", "did",
        "is", "are", "was", "were", "have", "has", "will",
    ]

    mutating func evaluate(utterances: [Utterance], elapsed: TimeInterval, context: PreCallContext) -> Nudge? {
        guard elapsed >= windowSeconds else { return nil }
        guard elapsed - lastFired >= cooldown else { return nil }

        // Only check "You" utterances in the last window.
        let windowStart = elapsed - windowSeconds
        let recentYou = utterances.filter { $0.isYou && $0.t >= windowStart }

        let hasQuestion = recentYou.contains { utt in
            Self.isQuestion(utt.text)
        }

        guard !hasQuestion else { return nil }

        lastFired = elapsed
        return Nudge(
            id: UUID(),
            type: .missingDiscovery,
            text: "Ask them something",
            urgency: .med,
            timestamp: elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
    }

    /// Check if text contains a question — sentences ending in `?` or starting with question words.
    static func isQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { return true }

        let lower = trimmed.lowercased()
        let sentences = lower.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        for sentence in sentences {
            let words = sentence.trimmingCharacters(in: .whitespaces)
                .split(separator: " ")
            guard let firstWord = words.first else { continue }
            if questionStarters.contains(String(firstWord)) {
                return true
            }
        }
        return false
    }
}
