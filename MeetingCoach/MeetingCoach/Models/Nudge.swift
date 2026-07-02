import Foundation

struct Nudge: Identifiable, Codable {
    let id: UUID
    let type: NudgeType
    let text: String              // 6 words max
    let urgency: NudgeUrgency
    let timestamp: TimeInterval   // call-relative
    var feedback: NudgeFeedback?

    var formattedTime: String {
        let mm = Int(timestamp) / 60
        let ss = Int(timestamp) % 60
        return String(format: "%02d:%02d", mm, ss)
    }
}

enum NudgeType: String, Codable, CaseIterable {
    case talkTime, missingDiscovery, timeCheck,
         repetitionLoop, stackedQuestions, nextSteps,
         goingQuiet, yesMan, unansweredQuestion, interruption,
         commitmentGap, droppedThread, priceFlinch, vagueAnswer,
         overrun, voiceShare, questionParked,
         // Tier-2 semantic signals (local LLM heartbeat)
         noDecision, alignmentReached, buriedSignal, hedgeNotPinned

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
        case .noDecision: return "No Decision"
        case .alignmentReached: return "Converged"
        case .buriedSignal: return "Buried Signal"
        case .hedgeNotPinned: return "Pin the Date"
        }
    }
}

enum NudgeUrgency: String, Codable { case low, med, high }
enum NudgeFeedback: String, Codable { case useful, annoying, wrong }
