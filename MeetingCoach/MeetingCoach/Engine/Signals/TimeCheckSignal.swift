import Foundation

/// Signal #3: Fires when < 8 min remain and meeting goal keywords haven't appeared in transcript.
struct TimeCheckSignal: SignalMonitor {
    let nudgeType: NudgeType = .timeCheck

    /// Remaining time threshold to fire (seconds).
    var remainingThreshold: TimeInterval = 480  // 8 minutes
    /// Scheduled meeting duration (seconds).
    let scheduledDuration: TimeInterval

    private var hasFired = false
    // Incremental keyword tracking: only fresh utterances are scanned.
    private var goalKeywords: Set<String>?
    private var matchedKeywords: Set<String> = []

    init(scheduledMinutes: Int) {
        self.scheduledDuration = TimeInterval(scheduledMinutes * 60)
    }

    mutating func evaluate(_ input: SignalInput) -> Nudge? {
        guard !input.context.meetingGoal.isEmpty else { return nil }

        let keywords: Set<String>
        if let goalKeywords {
            keywords = goalKeywords
        } else {
            keywords = Self.extractKeywords(from: input.context.meetingGoal)
            goalKeywords = keywords
        }
        guard !keywords.isEmpty else { return nil }

        // Track keyword coverage on every tick (word-boundary, not substring —
        // "plan" must not match "airplane"), even before the firing window.
        for u in input.fresh where matchedKeywords.count < keywords.count {
            matchedKeywords.formUnion(keywords.intersection(TextAnalysis.words(u.text)))
        }

        guard !hasFired else { return nil }
        let remaining = scheduledDuration - input.elapsed
        guard remaining > 0, remaining <= remainingThreshold else { return nil }

        let matchRatio = Double(matchedKeywords.count) / Double(keywords.count)
        // If more than half the goal keywords appeared, goal is likely being addressed
        guard matchRatio < 0.5 else { return nil }

        hasFired = true
        let minutesLeft = Int(remaining / 60)
        return Nudge(
            id: UUID(),
            type: .timeCheck,
            text: "\(minutesLeft)min left, hit your goal",
            urgency: .high,
            timestamp: input.elapsed
        )
    }

    mutating func reset() {
        hasFired = false
        goalKeywords = nil
        matchedKeywords = []
    }

    /// Extract meaningful keywords from the goal string (skip stop words).
    private static func extractKeywords(from goal: String) -> Set<String> {
        let stopWords: Set<String> = [
            "a", "an", "the", "is", "are", "was", "were", "be", "been",
            "to", "of", "in", "on", "at", "for", "with", "and", "or",
            "but", "not", "this", "that", "it", "we", "they", "i", "my",
            "our", "their", "about", "get", "make", "do", "will", "can",
        ]
        return Set(TextAnalysis.words(goal).filter { $0.count > 2 && !stopWords.contains($0) })
    }
}
