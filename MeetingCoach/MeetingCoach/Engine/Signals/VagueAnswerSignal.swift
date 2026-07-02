import Foundation

/// Signal #11: Fires when the other person asks a direct question and the
/// user's answer is a hedge with nothing concrete in it — "I think Sean has
/// a document, I have to verify it" / "honestly, my memory confuses me".
///
/// Derived from real coaching notes: the two sharpest tells in a meeting
/// were both this one pattern — not knowing your own role in the top deal,
/// and not having read the most load-bearing doc of your strategy.
struct VagueAnswerSignal: SignalMonitor {
    let nudgeType: NudgeType = .vagueAnswer

    /// The You answer must be at least this long to judge (a 3-word reply
    /// may still be mid-thought).
    var minAnswerWords: Int = 6
    /// Stop judging once the answer runs long — hedged openers followed by
    /// real substance are fine.
    var maxAnswerWords: Int = 60
    /// Minimum words in their question for it to count as substantive.
    var minQuestionWords: Int = 4
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 120

    private var lastFired: TimeInterval = -.infinity
    /// One nudge per question — latch on the Them turn that asked it.
    private var nudgedQuestionIDs: Set<UUID> = []

    /// Hedge phrases (matched on word boundaries, apostrophe-normalized).
    private static let hedgeMarkers: [String] = [
        "i think", "i believe", "i guess", "i assume", "probably", "maybe",
        "not sure", "i'm not sure", "i don't remember", "i don't recall",
        "my memory", "if i remember", "i have to check", "i have to verify",
        "i'll have to check", "i'll have to verify", "have to look",
        "i want to say", "something like that", "or something", "somewhere",
    ]

    mutating func evaluate(_ input: SignalInput) -> Nudge? {
        guard input.speakerLabelsReliable else { return nil }
        guard input.elapsed - lastFired >= cooldown else { return nil }
        let turns = input.turns
        guard turns.count >= 2 else { return nil }

        // Pattern: Them asked a substantive question, the You turn answering
        // it is hedgy and contains nothing concrete.
        let youTurn = turns[turns.count - 1]
        let themTurn = turns[turns.count - 2]
        guard youTurn.isYou,
              !themTurn.isYou, themTurn.speaker != "Meeting",
              youTurn.wordCount >= minAnswerWords,
              youTurn.wordCount <= maxAnswerWords,
              !nudgedQuestionIDs.contains(themTurn.id),
              themTurn.wordCount >= minQuestionWords,
              TextAnalysis.isQuestion(themTurn.text)
        else { return nil }

        let hedged = Self.hedgeMarkers.contains { TextAnalysis.containsPhrase(youTurn.text, $0) }
        guard hedged, !Self.hasConcreteAnchor(youTurn.text) else { return nil }

        lastFired = input.elapsed
        nudgedQuestionIDs.insert(themTurn.id)
        return Nudge(
            id: UUID(),
            type: .vagueAnswer,
            text: "That was a guess — pin it down",
            urgency: .med,
            timestamp: input.elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
        nudgedQuestionIDs = []
    }

    /// Anything concrete rescues a hedged answer: a number, a date word,
    /// or a named commitment to close the loop ("I'll send it Friday").
    static func hasConcreteAnchor(_ text: String) -> Bool {
        if text.contains(where: \.isNumber) { return true }
        let anchors: Set<String> = [
            "monday", "tuesday", "wednesday", "thursday", "friday",
            "saturday", "sunday", "today", "tomorrow", "tonight",
            "january", "february", "march", "april", "may", "june", "july",
            "august", "september", "october", "november", "december",
        ]
        return !anchors.isDisjoint(with: TextAnalysis.words(text))
    }
}
