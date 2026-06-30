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
        // Load adaptive multipliers from user feedback history
        let m = AdaptiveThresholds.multiplier

        var talkTime = TalkTimeSignal()
        talkTime.threshold *= m(.talkTime)
        talkTime.cooldown *= m(.talkTime)

        var discovery = MissingDiscoverySignal()
        discovery.windowSeconds *= m(.missingDiscovery)
        discovery.cooldown *= m(.missingDiscovery)

        var repetition = RepetitionLoopSignal()
        repetition.cooldown *= m(.repetitionLoop)

        var stacked = StackedQuestionsSignal()
        stacked.cooldown *= m(.stackedQuestions)

        var nextSteps = NextStepsSignal(scheduledMinutes: context.scheduledDurationMinutes)
        nextSteps.cooldown *= m(.nextSteps)

        var goingQuiet = GoingQuietSignal()
        goingQuiet.cooldown *= m(.goingQuiet)

        var yesMan = YesManSignal()
        yesMan.cooldown *= m(.yesMan)

        var unanswered = UnansweredQuestionSignal()
        unanswered.cooldown *= m(.unansweredQuestion)

        var interruption = InterruptionSignal()
        interruption.cooldown *= m(.interruption)

        monitors = [
            talkTime,
            discovery,
            TimeCheckSignal(scheduledMinutes: context.scheduledDurationMinutes),
            repetition,
            stacked,
            nextSteps,
            goingQuiet,
            yesMan,
            unanswered,
            interruption,
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
