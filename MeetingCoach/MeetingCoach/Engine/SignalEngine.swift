import Foundation

/// Everything a signal sees on one evaluation tick.
struct SignalInput {
    /// Full utterance history (raw ASR fragments).
    let utterances: [Utterance]
    /// Coalesced speaker turns — prefer these over raw utterances.
    let turns: [Turn]
    /// Utterances appended since the previous evaluate call. Signals that
    /// track full-history flags (phrase seen, keywords matched) scan only
    /// this slice, keeping each tick O(new) instead of O(total).
    let fresh: ArraySlice<Utterance>
    let elapsed: TimeInterval
    let context: PreCallContext
    /// False when speaker labels look like diarization noise (rapid-fire
    /// tiny turns). Signals that reason about WHO said something should
    /// stand down rather than hallucinate patterns from bad labels.
    let speakerLabelsReliable: Bool
}

/// Protocol that each deterministic signal implements.
protocol SignalMonitor {
    var nudgeType: NudgeType { get }
    mutating func evaluate(_ input: SignalInput) -> Nudge?
    mutating func reset()
}

/// Orchestrator for deterministic signals. Runs all monitors on each tick
/// and collects nudges for the live session and post-call review.
struct SignalEngine {
    private var monitors: [any SignalMonitor]
    private(set) var allNudges: [Nudge] = []

    // Incremental turn building
    private var turnBuilder = TurnBuilder()
    private var processedCount = 0
    private var lastProcessedID: UUID?

    var turns: [Turn] { turnBuilder.turns }

    init(context: PreCallContext) {
        // Two threshold layers: the meeting type sets the baseline (long
        // turns are the FORMAT of a 1:1 but a red flag on a sales call),
        // then adaptive multipliers from user feedback fine-tune it.
        let kind = context.effectiveMeetingType
        let m = AdaptiveThresholds.multiplier

        var talkTime = TalkTimeSignal()
        talkTime.threshold *= m(.talkTime) * kind.talkTimeMultiplier
        talkTime.cooldown *= m(.talkTime) * kind.talkTimeMultiplier

        var discovery = MissingDiscoverySignal()
        discovery.windowSeconds *= m(.missingDiscovery) * kind.discoveryMultiplier
        discovery.cooldown *= m(.missingDiscovery) * kind.discoveryMultiplier

        var repetition = RepetitionLoopSignal()
        repetition.cooldown *= m(.repetitionLoop)

        var stacked = StackedQuestionsSignal()
        stacked.cooldown *= m(.stackedQuestions)

        var nextSteps = NextStepsSignal(scheduledMinutes: context.scheduledDurationMinutes)
        nextSteps.cooldown *= m(.nextSteps)

        var goingQuiet = GoingQuietSignal()
        goingQuiet.cooldown *= m(.goingQuiet) * kind.engagementMultiplier
        goingQuiet.warmupSeconds *= kind.engagementMultiplier

        var yesMan = YesManSignal()
        yesMan.cooldown *= m(.yesMan) * kind.engagementMultiplier

        var unanswered = UnansweredQuestionSignal()
        unanswered.cooldown *= m(.unansweredQuestion)

        var interruption = InterruptionSignal()
        interruption.cooldown *= m(.interruption)

        var vague = VagueAnswerSignal()
        vague.cooldown *= m(.vagueAnswer)

        var voiceShare = VoiceShareSignal()
        voiceShare.shareThreshold = min(0.9, voiceShare.shareThreshold * m(.voiceShare) * kind.talkTimeMultiplier.squareRoot())
        voiceShare.cooldown *= m(.voiceShare)

        // Positive reinforcement — feedback adapts frequency like any other
        // signal ("useful" makes green more common, "annoying" rarer).
        var questionLanded = QuestionLandedSignal()
        questionLanded.cooldown *= m(.questionLanded)
        var ownership = PositiveSignals.ownershipHanded()
        ownership.cooldown *= m(.ownershipHanded)
        var refocused = PositiveSignals.refocused()
        refocused.cooldown *= m(.refocused)
        var locked = PositiveSignals.commitmentLocked()
        locked.cooldown *= m(.commitmentLocked)
        var reflected = PositiveSignals.reflectedBack()
        reflected.cooldown *= m(.reflectedBack)

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
            vague,
            OverrunSignal(scheduledMinutes: context.scheduledDurationMinutes),
            voiceShare,
            HighStakesSignal(),
            QuestionParkedSignal(),
            questionLanded,
            ownership,
            refocused,
            locked,
            reflected,
        ]
    }

    /// Force the next evaluate() to rebuild turns from scratch — used when
    /// utterance history was edited in place (diarization relabeled speakers).
    mutating func invalidateTurnCache() {
        processedCount = 0
        lastProcessedID = nil
        // Must clear the built turns too: evaluate() treats processedCount==0
        // as append-from-scratch, so stale turns would be duplicated.
        turnBuilder.reset()
    }

    /// Run all monitors against current state. Returns any new nudges.
    mutating func evaluate(utterances: [Utterance], elapsed: TimeInterval, context: PreCallContext) -> [Nudge] {
        // Update turns incrementally when the array only grew by appends;
        // rebuild on any other shape change (out-of-order insert, reload).
        let isAppendOnly = processedCount <= utterances.count
            && (processedCount == 0 || (processedCount <= utterances.count
                && utterances[processedCount - 1].id == lastProcessedID))

        let freshStart: Int
        if isAppendOnly {
            freshStart = processedCount
            for u in utterances[processedCount...] {
                turnBuilder.append(u)
            }
        } else {
            freshStart = 0
            turnBuilder.rebuild(utterances)
        }
        processedCount = utterances.count
        lastProcessedID = utterances.last?.id

        let input = SignalInput(
            utterances: utterances,
            turns: turnBuilder.turns,
            fresh: utterances[freshStart...],
            elapsed: elapsed,
            context: context,
            speakerLabelsReliable: Self.labelsReliable(turnBuilder.turns)
        )

        var newNudges: [Nudge] = []
        for i in monitors.indices {
            if let nudge = monitors[i].evaluate(input) {
                newNudges.append(nudge)
                allNudges.append(nudge)
            }
        }
        return newNudges
    }

    /// Diarization sanity check over the recent turns: real conversation has
    /// substantial turns; label noise shows up as rapid-fire tiny turns
    /// (speaker flipping every few words). Median recent turn length below
    /// ~5 words means the labels can't be trusted for who-said-what signals.
    private static func labelsReliable(_ turns: [Turn]) -> Bool {
        let recent = turns.suffix(30)
        guard recent.count >= 10 else { return true }  // too early to judge
        let sorted = recent.map(\.wordCount).sorted()
        let median = sorted[sorted.count / 2]
        return median >= 5
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
        turnBuilder.reset()
        processedCount = 0
        lastProcessedID = nil
    }
}
