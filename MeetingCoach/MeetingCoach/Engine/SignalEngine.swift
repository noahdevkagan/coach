import Foundation

/// Protocol that each deterministic signal implements.
protocol SignalMonitor {
    var nudgeType: NudgeType { get }
    mutating func evaluate(utterances: [Utterance], elapsed: TimeInterval, context: PreCallContext) -> Nudge?
    mutating func reset()
}

/// Orchestrator for deterministic signals. Runs all monitors on each tick
/// and collects nudges for the live session and post-call review.
struct SignalEngine {
    private var monitors: [any SignalMonitor]
    private(set) var allNudges: [Nudge] = []

    init(context: PreCallContext) {
        monitors = [
            TalkTimeSignal(),
            MissingDiscoverySignal(),
            TimeCheckSignal(scheduledMinutes: context.scheduledDurationMinutes),
        ]
    }

    /// Run all monitors against current state. Returns any new nudges.
    mutating func evaluate(utterances: [Utterance], elapsed: TimeInterval, context: PreCallContext) -> [Nudge] {
        var newNudges: [Nudge] = []
        for i in monitors.indices {
            if let nudge = monitors[i].evaluate(utterances: utterances, elapsed: elapsed, context: context) {
                newNudges.append(nudge)
                allNudges.append(nudge)
            }
        }
        return newNudges
    }

    mutating func recordFeedback(nudgeId: UUID, feedback: NudgeFeedback) {
        if let i = allNudges.firstIndex(where: { $0.id == nudgeId }) {
            allNudges[i].feedback = feedback
        }
    }

    mutating func reset() {
        for i in monitors.indices {
            monitors[i].reset()
        }
        allNudges = []
    }
}
