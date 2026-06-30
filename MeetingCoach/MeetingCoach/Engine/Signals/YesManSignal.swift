import Foundation

/// Signal #8: Fires when the other person gives 3+ consecutive
/// agreement-only responses without substance.
struct YesManSignal: SignalMonitor {
    let nudgeType: NudgeType = .yesMan

    /// How many consecutive agreement-only replies trigger the nudge.
    var consecutiveThreshold: Int = 3
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 120

    private var lastFired: TimeInterval = -.infinity

    private static let agreementPhrases: Set<String> = [
        "yeah", "yes", "yep", "yup", "sure", "right", "okay", "ok",
        "got it", "makes sense", "totally", "absolutely", "exactly",
        "for sure", "correct", "agreed", "uh huh", "uh-huh", "mm hmm",
        "mmhmm", "mm-hmm", "sounds good", "fair enough",
    ]

    mutating func evaluate(utterances: [Utterance], elapsed: TimeInterval, context: PreCallContext) -> Nudge? {
        guard elapsed - lastFired >= cooldown else { return nil }

        // Walk backwards through utterances, counting consecutive "Them" agreement-only turns
        var consecutiveAgreements = 0
        for utt in utterances.reversed() {
            if utt.isYou || utt.speaker == "Meeting" {
                // Skip "You" turns — we're looking for consecutive "Them" patterns
                // But if we already found some agreements, the streak continues across You turns
                if consecutiveAgreements > 0 { continue }
                break
            }
            // It's a "Them" utterance
            if Self.isAgreementOnly(utt.text) {
                consecutiveAgreements += 1
            } else {
                break
            }
        }

        guard consecutiveAgreements >= consecutiveThreshold else { return nil }

        lastFired = elapsed
        return Nudge(
            id: UUID(),
            type: .yesMan,
            text: "They're just agreeing — probe deeper",
            urgency: .med,
            timestamp: elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
    }

    static func isAgreementOnly(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = lower.split(separator: " ")
        // Very short reply
        guard words.count <= 6 else { return false }
        // Check if the whole text is an agreement phrase
        if agreementPhrases.contains(lower) { return true }
        // Check if it's just filler + agreement
        let cleaned = lower.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespaces)
        if agreementPhrases.contains(cleaned) { return true }
        // Check if every word is an agreement word
        let agreementWords: Set<String> = ["yeah", "yes", "yep", "sure", "right", "okay", "ok", "got", "it", "totally", "absolutely", "exactly", "agreed", "correct", "mm", "hmm", "uh", "huh", "sounds", "good", "makes", "sense", "fair", "enough", "for"]
        return !words.isEmpty && words.allSatisfy { agreementWords.contains(String($0)) }
    }
}
