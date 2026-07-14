import Foundation

// Positive reinforcement signals — praise the behaviors the coaching notes
// keep flagging as wins, the moment they happen. Sourced from real meeting
// analysis ("What worked" write-ups) and phrase-checked against saved
// sessions so the detectors match how Noah actually talks.
//
// Reinforcement only works if it's rare: every signal here has a long
// cooldown and a per-meeting fire cap, so a good meeting earns a handful of
// green nudges, not a cheerleader.

/// Generic phrase-triggered reinforcement: fires when the user (You) says
/// one of the marker phrases. Precision-first — short lists of unambiguous
/// phrases beat broad ones that train the user to ignore green.
struct PositivePhraseSignal: SignalMonitor {
    let nudgeType: NudgeType
    let text: String
    let phrases: [String]
    /// Don't fire before this point — "zoom out" at minute 1 isn't a save.
    var minElapsed: TimeInterval = 0
    var cooldown: TimeInterval = 300
    var maxFires: Int = 2

    private var fires = 0
    private var lastFired: TimeInterval = -.infinity

    init(type: NudgeType, text: String, phrases: [String],
         minElapsed: TimeInterval = 0, cooldown: TimeInterval = 300, maxFires: Int = 2) {
        self.nudgeType = type
        self.text = text
        self.phrases = phrases
        self.minElapsed = minElapsed
        self.cooldown = cooldown
        self.maxFires = maxFires
    }

    mutating func evaluate(_ input: SignalInput) -> Nudge? {
        guard fires < maxFires,
              input.elapsed >= minElapsed,
              input.elapsed - lastFired >= cooldown,
              input.speakerLabelsReliable else { return nil }

        for u in input.fresh where u.isYou {
            if phrases.contains(where: { TextAnalysis.containsPhrase(u.text, $0) }) {
                fires += 1
                lastFired = input.elapsed
                return Nudge(id: UUID(), type: nudgeType, text: text,
                             urgency: .low, timestamp: input.elapsed)
            }
        }
        return nil
    }

    mutating func reset() {
        fires = 0
        lastFired = -.infinity
    }
}

/// Fires when a short, open question from You pulls a long answer from Them —
/// the question WORKED. The coaching notes credit exactly these ("what should
/// I know that I don't", the chair-swap question, "anything else I should
/// ask") with surfacing the realest material in the meeting.
struct QuestionLandedSignal: SignalMonitor {
    let nudgeType: NudgeType = .questionLanded

    /// The question must be short — a 100-word turn ending in "?" is a
    /// monologue, not an open question.
    var maxQuestionWords = 30
    /// How much they talk before the question counts as landed.
    var minAnswerWords = 45
    var cooldown: TimeInterval = 240
    var maxFires: Int = 3

    /// Open-question markers: wh-starters plus the invitation phrases from
    /// the coaching notes. Closed yes/no questions don't open people up.
    private static let openMarkers: [String] = [
        "what", "how", "why", "walk me through", "tell me",
        "what's your", "what should i know", "what am i missing",
        "anything else", "what would you",
    ]

    private var fires = 0
    private var lastFired: TimeInterval = -.infinity
    private var latchedAnswerIDs: Set<UUID> = []

    mutating func evaluate(_ input: SignalInput) -> Nudge? {
        guard fires < maxFires,
              input.elapsed - lastFired >= cooldown,
              input.speakerLabelsReliable else { return nil }
        let turns = input.turns
        guard turns.count >= 2 else { return nil }

        // Last turn: Them, talking at length (may still be growing — firing
        // mid-answer is the point: reinforce while the silence is working).
        let answer = turns[turns.count - 1]
        let question = turns[turns.count - 2]
        guard !answer.isYou, answer.speaker != "Meeting",
              answer.wordCount >= minAnswerWords,
              !latchedAnswerIDs.contains(answer.id),
              question.isYou,
              question.wordCount <= maxQuestionWords,
              TextAnalysis.isQuestion(question.text),
              Self.isOpen(question.text)
        else { return nil }

        fires += 1
        lastFired = input.elapsed
        latchedAnswerIDs.insert(answer.id)
        return Nudge(id: UUID(), type: .questionLanded,
                     text: "Great question — they opened up",
                     urgency: .low, timestamp: input.elapsed)
    }

    private static func isOpen(_ text: String) -> Bool {
        openMarkers.contains { TextAnalysis.containsPhrase(text, $0) }
    }

    mutating func reset() {
        fires = 0
        lastFired = -.infinity
        latchedAnswerIDs = []
    }
}

/// Factory for the phrase-based reinforcement set, so SignalEngine reads as
/// one line and the phrase lists live next to their rationale.
enum PositiveSignals {

    /// "Nothing — you make the call, figure out the timing" turned the
    /// hardest relationship around; the coached watch-item is not clawing
    /// the decision back afterward. The nudge text carries both.
    static func ownershipHanded() -> PositivePhraseSignal {
        PositivePhraseSignal(
            type: .ownershipHanded,
            text: "Ownership handed — don't claw it back",
            phrases: [
                "you make the call", "your call", "you decide",
                "you own this", "you own it", "it's your decision",
                "run with it", "up to you", "ship it",
            ],
            cooldown: 300, maxFires: 2)
    }

    /// The "what are we trying to answer?" intervention is praised in the
    /// notes as exactly right but 20 minutes late — reinforcing each catch
    /// trains the reflex to fire sooner.
    static func refocused() -> PositivePhraseSignal {
        PositivePhraseSignal(
            type: .refocused,
            text: "Good catch — room refocused",
            phrases: [
                "zoom out", "step back", "take a step back",
                "what are we trying to answer", "what are we actually trying",
                "take it offline", "take this offline", "sync offline",
                "talk offline", "park that", "park it", "back to the agenda",
            ],
            minElapsed: 480, cooldown: 300, maxFires: 2)
    }

    /// Commitments locked — owner named, next step booked — is the most
    /// consistent "what worked" item, and it counts mid-meeting too ("what
    /// would next steps be?" at minute 8 booked the follow-up on the
    /// littlebird call). Only the first minutes are gated: that's agenda
    /// talk, not a close.
    static func commitmentLocked() -> PositivePhraseSignal {
        PositivePhraseSignal(
            type: .commitmentLocked,
            text: "Clean close — commitments locked",
            // Commitment-shaped phrases only. Bare "next steps" / "action
            // item" false-positived on topic talk ("here's the next steps"
            // describing a doc) in the 07-14 backtest.
            phrases: [
                "who owns", "by when",
                "what are the next steps", "what would next steps be",
                "what's the next step", "our next steps",
                "the action items are", "action item is",
                "let's recap", "to summarize", "you'll have it by",
                "what are you taking away",
            ],
            minElapsed: 300,
            cooldown: 600, maxFires: 2)
    }

    /// "Really listen until 'yes, exactly'" — reflecting their point back is
    /// the most-coached gap; when it happens it should light up green.
    static func reflectedBack() -> PositivePhraseSignal {
        PositivePhraseSignal(
            type: .reflectedBack,
            text: "Nice reflect — they feel heard",
            phrases: [
                "sounds like you", "sounds like we", "so you're saying",
                "what i'm hearing", "if i'm hearing you", "your point is",
                "let me play that back", "am i hearing that right",
            ],
            cooldown: 300, maxFires: 2)
    }
}
