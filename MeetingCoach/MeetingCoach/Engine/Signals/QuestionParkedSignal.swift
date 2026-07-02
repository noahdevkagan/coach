import Foundation

/// Signal #15: Fires when the user keeps re-asking the same substantive
/// question because it never gets answered — it's being parked.
///
/// Derived from a real blind test: the user asked "what's the scorecard to
/// know we're trending right?" three-plus times across a meeting, it got
/// parked as "a thing to think on," and the post-meeting coach called it the
/// single most important unresolved deliverable. UnansweredQuestionSignal
/// watches THEIR questions at you; nobody was watching yours.
struct QuestionParkedSignal: SignalMonitor {
    let nudgeType: NudgeType = .questionParked

    /// How similar two question turns must be to count as a re-ask.
    var similarityThreshold: Double = 0.45
    /// Number of asks before nudging (3rd ask = it's being dodged).
    var askThreshold: Int = 3
    /// How far back an earlier ask stays relevant (seconds).
    var windowSeconds: TimeInterval = 1500
    /// Minimum content words in the question to track it.
    var minWords: Int = 4
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 240

    private var lastFired: TimeInterval = -.infinity
    /// (turn id, time, content words) for each substantive You question seen.
    private var askedQuestions: [(id: UUID, t: TimeInterval, words: Set<String>)] = []
    /// Question content that already produced a nudge.
    private var firedContent: [Set<String>] = []

    mutating func evaluate(_ input: SignalInput) -> Nudge? {
        guard input.speakerLabelsReliable else { return nil }
        guard let turn = input.turns.last, turn.isYou else { return nil }
        guard !askedQuestions.contains(where: { $0.id == turn.id }) else { return nil }
        guard Self.asksQuestion(turn.text) else { return nil }

        let words = TextAnalysis.contentWords(turn.text)
        guard words.count >= minWords else { return nil }
        askedQuestions.append((turn.id, turn.t, words))

        guard input.elapsed - lastFired >= cooldown else { return nil }

        // Latch: this question already nudged.
        guard !firedContent.contains(where: {
            TextAnalysis.jaccard(words, $0) >= similarityThreshold
        }) else { return nil }

        // Count semantically similar earlier asks in the window.
        let windowStart = input.elapsed - windowSeconds
        let asks = askedQuestions.filter {
            $0.t >= windowStart && TextAnalysis.jaccard(words, $0.words) >= similarityThreshold
        }
        guard asks.count >= askThreshold else { return nil }

        lastFired = input.elapsed
        firedContent.append(words)
        if firedContent.count > 10 { firedContent.removeFirst() }
        return Nudge(
            id: UUID(),
            type: .questionParked,
            text: "3rd time asking — get an answer",
            urgency: .high,
            timestamp: input.elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
        askedQuestions = []
        firedContent = []
    }

    /// Broader than TextAnalysis.isQuestion: real speech embeds the big asks
    /// mid-sentence ("I think the question is, like, what's the scorecard…")
    /// with no question mark and no sentence-initial wh-word.
    static func asksQuestion(_ text: String) -> Bool {
        if TextAnalysis.isQuestion(text) { return true }
        return ["question is", "my question", "question for", "what i want to know",
                "the thing i keep asking"].contains { TextAnalysis.containsPhrase(text, $0) }
    }
}
