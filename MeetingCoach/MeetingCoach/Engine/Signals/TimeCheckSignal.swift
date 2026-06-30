import Foundation

/// Signal #3: Fires when < 8 min remain and meeting goal keywords haven't appeared in transcript.
struct TimeCheckSignal: SignalMonitor {
    let nudgeType: NudgeType = .timeCheck

    /// Remaining time threshold to fire (seconds).
    var remainingThreshold: TimeInterval = 480  // 8 minutes
    /// Scheduled meeting duration (seconds).
    let scheduledDuration: TimeInterval

    private var hasFired = false

    init(scheduledMinutes: Int) {
        self.scheduledDuration = TimeInterval(scheduledMinutes * 60)
    }

    mutating func evaluate(utterances: [Utterance], elapsed: TimeInterval, context: PreCallContext) -> Nudge? {
        guard !hasFired else { return nil }
        guard !context.meetingGoal.isEmpty else { return nil }

        let remaining = scheduledDuration - elapsed
        guard remaining > 0, remaining <= remainingThreshold else { return nil }

        // Check if goal keywords appear in transcript
        let goalKeywords = extractKeywords(from: context.meetingGoal)
        guard !goalKeywords.isEmpty else { return nil }

        let fullText = utterances.map(\.text).joined(separator: " ").lowercased()
        let matchCount = goalKeywords.filter { fullText.contains($0) }.count
        let matchRatio = Double(matchCount) / Double(goalKeywords.count)

        // If more than half the goal keywords appeared, goal is likely being addressed
        guard matchRatio < 0.5 else { return nil }

        hasFired = true
        let minutesLeft = Int(remaining / 60)
        return Nudge(
            id: UUID(),
            type: .timeCheck,
            text: "\(minutesLeft)min left, hit your goal",
            urgency: .high,
            timestamp: elapsed
        )
    }

    mutating func reset() {
        hasFired = false
    }

    /// Extract meaningful keywords from the goal string (skip stop words).
    private func extractKeywords(from goal: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "an", "the", "is", "are", "was", "were", "be", "been",
            "to", "of", "in", "on", "at", "for", "with", "and", "or",
            "but", "not", "this", "that", "it", "we", "they", "i", "my",
            "our", "their", "about", "get", "make", "do", "will", "can",
        ]
        return goal.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }
}
