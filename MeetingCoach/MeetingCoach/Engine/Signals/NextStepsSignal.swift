import Foundation

/// Signal #6: Fires in the last 20% of scheduled meeting time if no one has
/// mentioned action items, next steps, owners, or deadlines. Fires at most
/// twice: once entering the window, once more in the final 2 minutes.
struct NextStepsSignal: SignalMonitor {
    let nudgeType: NudgeType = .nextSteps

    let scheduledDuration: TimeInterval
    /// Fire when this fraction of time remains (0.2 = last 20%).
    var triggerFraction: Double = 0.20
    /// Second (final) warning point, seconds remaining.
    var finalWarningSeconds: TimeInterval = 120
    /// Kept for adaptive-threshold compatibility (scales nothing time-based
    /// here anymore, but multiplied by the engine on init).
    var cooldown: TimeInterval = 120

    private var firedStages = 0
    private var hasSeenNextSteps = false

    /// Phrases that indicate next-step / commitment language. Matched on
    /// word boundaries with apostrophes normalized ("I'll" vs "I'll").
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

    mutating func evaluate(_ input: SignalInput) -> Nudge? {
        guard scheduledDuration > 0 else { return nil }

        // Incremental: scan only fresh utterances for next-step language.
        if !hasSeenNextSteps {
            for u in input.fresh {
                if Self.nextStepPhrases.contains(where: { TextAnalysis.containsPhrase(u.text, $0) }) {
                    hasSeenNextSteps = true
                    break
                }
            }
        }
        guard !hasSeenNextSteps else { return nil }

        let remaining = scheduledDuration - input.elapsed
        guard remaining > 0 else { return nil }

        // Stage 1: entering the last 20%. Stage 2: final-minutes warning.
        let stage: Int
        if remaining <= finalWarningSeconds {
            stage = 2
        } else if remaining <= scheduledDuration * triggerFraction {
            stage = 1
        } else {
            return nil
        }
        guard stage > firedStages else { return nil }

        firedStages = stage
        let minsLeft = max(1, Int(remaining / 60))
        return Nudge(
            id: UUID(),
            type: .nextSteps,
            text: "\(minsLeft)min left — lock down next steps",
            urgency: .high,
            timestamp: input.elapsed
        )
    }

    mutating func reset() {
        firedStages = 0
        hasSeenNextSteps = false
    }
}
