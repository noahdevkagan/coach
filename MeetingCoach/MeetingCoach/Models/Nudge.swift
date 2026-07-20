import Foundation

struct Nudge: Identifiable, Codable {
    let id: UUID
    let type: NudgeType
    let text: String              // 6 words max
    let urgency: NudgeUrgency
    let timestamp: TimeInterval   // call-relative
    var feedback: NudgeFeedback?
    /// Machine-observed, not user-stated: the nudge held the overlay for
    /// its full display window and the user never touched it. Cleared if
    /// feedback arrives later (feed buttons). Optional so old encoded data
    /// still decodes; deliberately NOT a NudgeFeedback case so explicit
    /// feedback ratios stay undiluted.
    var wasIgnored: Bool?
    /// Set only for type == .custom: the rubric signal id (snake_case) and
    /// its display name. Optional so old encoded data still decodes.
    var customId: String?
    var customName: String?

    var formattedTime: String { mmss(timestamp) }

    /// Stable per-signal key for persistence and adaptive thresholds:
    /// the rawValue for built-ins, "custom:<id>" for rubric-defined signals.
    var typeKey: String {
        if type == .custom, let customId { return "custom:\(customId)" }
        return type.rawValue
    }

    /// What the UI badges show — rubric display name for custom signals.
    var badgeLabel: String {
        if type == .custom { return customName ?? "Custom" }
        return type.rawValue
    }
}

enum NudgeType: String, Codable, CaseIterable {
    case talkTime, missingDiscovery, timeCheck,
         repetitionLoop, stackedQuestions, nextSteps,
         goingQuiet, yesMan, unansweredQuestion, interruption,
         commitmentGap, droppedThread, priceFlinch, vagueAnswer,
         overrun, voiceShare, questionParked,
         // Positive reinforcement (deterministic) — behaviors the coaching
         // notes flag as wins, reinforced the moment they happen
         questionLanded, ownershipHanded, refocused,
         commitmentLocked, reflectedBack,
         // Tier-2 semantic signals (local LLM heartbeat)
         noDecision, alignmentReached, buriedSignal, hedgeNotPinned,
         // Rubric-defined semantic signal (see Nudge.customId/customName)
         custom

    var displayName: String {
        switch self {
        case .talkTime: return "Talk Time"
        case .missingDiscovery: return "No Questions"
        case .timeCheck: return "Time Check"
        case .repetitionLoop: return "Repetition"
        case .stackedQuestions: return "Stacked Qs"
        case .nextSteps: return "Next Steps"
        case .goingQuiet: return "They're Quiet"
        case .yesMan: return "Yes-Manning"
        case .unansweredQuestion: return "Their Question"
        case .interruption: return "Interruption"
        case .commitmentGap: return "Commitment"
        case .droppedThread: return "Dropped Thread"
        case .priceFlinch: return "Price Flinch"
        case .vagueAnswer: return "Vague Answer"
        case .overrun: return "Over Time"
        case .voiceShare: return "Floor Hog"
        case .questionParked: return "Parked Question"
        case .questionLanded: return "Question Landed"
        case .ownershipHanded: return "Handed Over"
        case .refocused: return "Refocused"
        case .commitmentLocked: return "Locked In"
        case .reflectedBack: return "Reflected"
        case .noDecision: return "No Decision"
        case .alignmentReached: return "Converged"
        case .buriedSignal: return "Buried Signal"
        case .hedgeNotPinned: return "Pin the Date"
        case .custom: return "Custom"
        }
    }

    /// Reinforcement, not correction — rendered green, worded as praise.
    var isPositive: Bool {
        switch self {
        case .questionLanded, .ownershipHanded, .refocused,
             .commitmentLocked, .reflectedBack, .alignmentReached:
            return true
        default:
            return false
        }
    }
}

enum NudgeUrgency: String, Codable { case low, med, high }
enum NudgeFeedback: String, Codable { case useful, annoying, wrong }
