import Foundation

/// Signal #8: Fires when the other person gives 3+ consecutive
/// agreement-only responses without substance.
struct YesManSignal: SignalMonitor {
    let nudgeType: NudgeType = .yesMan

    /// How many consecutive agreement-only replies trigger the nudge.
    var consecutiveThreshold: Int = 3
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 120
    /// How many turns back to walk when counting the streak.
    var maxLookback: Int = 10

    private var lastFired: TimeInterval = -.infinity

    private static let agreementPhrases: Set<String> = [
        "yeah", "yes", "yep", "yup", "sure", "right", "okay", "ok",
        "got it", "makes sense", "totally", "absolutely", "exactly",
        "for sure", "correct", "agreed", "uh huh", "uh-huh", "mm hmm",
        "mmhmm", "mm-hmm", "sounds good", "fair enough",
    ]

    mutating func evaluate(_ input: SignalInput) -> Nudge? {
        guard input.speakerLabelsReliable else { return nil }
        guard input.elapsed - lastFired >= cooldown else { return nil }

        // Walk backwards over TURNS counting consecutive Them agreement-only
        // replies. A "yes" that directly answers a You question is legitimate
        // and does not count toward the streak.
        var consecutiveAgreements = 0
        let turns = input.turns
        var i = turns.count - 1
        var walked = 0
        while i >= 0, walked < maxLookback {
            let turn = turns[i]
            walked += 1
            if turn.isYou || turn.speaker == "Meeting" {
                // Streak continues across You turns once started
                if consecutiveAgreements == 0 && turn.isYou { break }
                i -= 1
                continue
            }
            if Self.isAgreementOnly(turn.text) {
                // Direct answer to a question? Neutral — skip, don't count.
                let prevIsYouQuestion = i > 0 && turns[i - 1].isYou
                    && TextAnalysis.isQuestion(turns[i - 1].text)
                if !prevIsYouQuestion {
                    consecutiveAgreements += 1
                }
            } else {
                break
            }
            i -= 1
        }

        guard consecutiveAgreements >= consecutiveThreshold else { return nil }

        lastFired = input.elapsed
        return Nudge(
            id: UUID(),
            type: .yesMan,
            text: "They're just agreeing — probe deeper",
            urgency: .med,
            timestamp: input.elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
    }

    static func isAgreementOnly(_ text: String) -> Bool {
        let words = TextAnalysis.words(text)
        // Very short reply
        guard !words.isEmpty, words.count <= 6 else { return false }
        let joined = words.joined(separator: " ")
        if agreementPhrases.contains(joined) { return true }
        // Every word is an unambiguous agreement/filler word
        let agreementWords: Set<String> = [
            "yeah", "yes", "yep", "yup", "sure", "right", "okay", "ok",
            "totally", "absolutely", "exactly", "agreed", "correct",
            "mm", "hmm", "mhm", "uh", "huh", "cool", "perfect", "great",
            "awesome", "definitely", "gotcha", "alright", "fine",
        ]
        return words.allSatisfy { agreementWords.contains($0) }
    }
}
