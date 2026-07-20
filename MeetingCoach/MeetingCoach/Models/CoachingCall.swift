import Foundation

struct CoachingCall: Identifiable, Sendable {
    let id = UUID()
    let t: TimeInterval
    let signalId: String
    let confidence: Double
    let evidence: String
    let nudge: String
    let reason: TriggerReason

    var formattedTime: String { mmss(t) }

    var tierColor: String {
        // Tier A signals (structural) vs Tier B (tone/intent)
        let tierA = ["no_decision_owner_date", "alignment_reached_still_talking",
                     "reopening_closed_thread", "buried_signal_ignored"]
        return tierA.contains(signalId) ? "blue" : "orange"
    }
}
