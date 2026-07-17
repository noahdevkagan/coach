import Foundation

/// A curated coaching focus the user can pick on the dashboard (max two).
/// Focus is deliberately light-touch: focused signals get modestly more
/// sensitive, win the overlay when nudges collide, and lead the dashboard —
/// nothing else changes, so goals can't turn the coach into a nag.
struct FocusGoalDef: Identifiable, Sendable {
    let id: String
    let title: String
    let blurb: String
    /// Signals this goal sharpens and measures.
    let types: [NudgeType]
}

enum FocusGoals {
    static let maxActive = 2
    /// Focused signals fire a bit more eagerly (threshold multiplier).
    static let sensitivityBoost = 0.85

    static let catalog: [FocusGoalDef] = [
        FocusGoalDef(id: "talk_less", title: "Talk less",
                     blurb: "Hold the floor less; hand it back sooner.",
                     types: [.talkTime, .voiceShare]),
        FocusGoalDef(id: "stop_interrupting", title: "Stop interrupting",
                     blurb: "Let them finish before you start.",
                     types: [.interruption, .unansweredQuestion]),
        FocusGoalDef(id: "lock_decisions", title: "Lock decisions",
                     blurb: "Every open topic ends with owner and date.",
                     types: [.nextSteps, .commitmentGap, .hedgeNotPinned, .noDecision]),
        FocusGoalDef(id: "ask_better_questions", title: "Ask better questions",
                     blurb: "One open question at a time, then silence.",
                     types: [.missingDiscovery, .stackedQuestions, .questionLanded]),
        FocusGoalDef(id: "listen_reflect", title: "Listen & reflect",
                     blurb: "Reflect their point back before responding.",
                     types: [.reflectedBack, .yesMan, .buriedSignal]),
    ]

    static func definition(for id: String) -> FocusGoalDef? {
        catalog.first { $0.id == id }
    }

    // MARK: - Persistence (goals.json in Application Support)

    static func loadActiveIds() -> [String] {
        guard let data = try? Data(contentsOf: AppSupport.goalsURL),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Array(ids.filter { definition(for: $0) != nil }.prefix(maxActive))
    }

    static func saveActiveIds(_ ids: [String]) {
        AppSupport.ensureLayout()
        let capped = Array(ids.prefix(maxActive))
        if let data = try? JSONEncoder().encode(capped) {
            try? data.write(to: AppSupport.goalsURL, options: .atomic)
        }
    }

    /// Union of signal types across the active goals.
    static func activeTypes() -> Set<NudgeType> {
        Set(loadActiveIds().compactMap(definition(for:)).flatMap(\.types))
    }
}
