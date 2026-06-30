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
         commitmentGap, droppedThread, priceFlinch
}

enum NudgeUrgency: String, Codable { case low, med, high }
enum NudgeFeedback: String, Codable { case useful, annoying, wrong }
