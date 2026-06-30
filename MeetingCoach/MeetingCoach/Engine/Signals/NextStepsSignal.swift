import Foundation

/// Signal #6: Fires in the last 20% of scheduled meeting time if no one has
/// mentioned action items, next steps, owners, or deadlines.
struct NextStepsSignal: SignalMonitor {
    let nudgeType: NudgeType = .nextSteps

    let scheduledDuration: TimeInterval
    /// Fire when this fraction of time remains (0.2 = last 20%).
    var triggerFraction: Double = 0.20
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 120

    private var lastFired: TimeInterval = -.infinity

    /// Phrases that indicate next-step / commitment language.
    private static let nextStepPhrases: [String] = [
        "next step", "next steps", "action item", "action items",
        "follow up", "follow-up", "followup",
        "i'll send", "i will send", "i'll share", "i will share",
        "let's schedule", "let's set up", "let's book",
        "by friday", "by monday", "by tuesday", "by wednesday", "by thursday",
        "by end of", "by next week", "by tomorrow",
        "deadline", "due date", "owner", "owns this", "who owns",
        "responsible for", "take the lead", "i'll take", "you'll take",
        "i'll handle", "you'll handle", "assigned to",
        "wrap up", "to summarize", "in summary",
    ]

    init(scheduledMinutes: Int) {
        scheduledDuration = TimeInterval(scheduledMinutes * 60)
    }

    mutating func evaluate(utterances: [Utterance], elapsed: TimeInterval, context: PreCallContext) -> Nudge? {
        guard elapsed - lastFired >= cooldown else { return nil }
        guard scheduledDuration > 0 else { return nil }

        let remaining = scheduledDuration - elapsed
        let triggerPoint = scheduledDuration * triggerFraction
        guard remaining > 0, remaining <= triggerPoint else { return nil }

        // Check if any next-step language has appeared in the transcript
        let fullText = utterances.map(\.text).joined(separator: " ").lowercased()
        let hasNextSteps = Self.nextStepPhrases.contains { fullText.contains($0) }
        guard !hasNextSteps else { return nil }

        lastFired = elapsed
        let minsLeft = max(1, Int(remaining / 60))
        return Nudge(
            id: UUID(),
            type: .nextSteps,
            text: "\(minsLeft)min left — lock down next steps",
            urgency: .high,
            timestamp: elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
    }
}
