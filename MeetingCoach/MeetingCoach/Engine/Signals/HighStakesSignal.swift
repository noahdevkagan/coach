import Foundation

/// Signal #14: Tripwire for statements that are ALWAYS high-stakes — someone
/// mentioning leaving, quitting, burnout, or being recruited. Fires when the
/// conversation moves past one without the user engaging it.
///
/// Derived from a real miss: an engineer said "…me thinking I'm just gonna
/// leave the company…" as a subordinate clause mid-ramble, and the moment
/// passed with no follow-up. The post-meeting coach called it the headline
/// of the entire conversation. This class of phrase never needs an LLM —
/// a tripwire is cheaper and never blinks.
struct HighStakesSignal: SignalMonitor {
    let nudgeType: NudgeType = .buriedSignal

    /// The user has this long (after the Them turn ends) to engage before
    /// the nudge fires. Engaging = a You turn mentioning related words.
    var engageWindowSeconds: TimeInterval = 25
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 180

    private var lastFired: TimeInterval = -.infinity
    /// One nudge per triggering turn.
    private var firedTurnIDs: Set<UUID> = []

    /// Phrases from the other side that always deserve a beat of attention.
    private static let tripwires: [String] = [
        "leave the company", "leaving the company", "gonna leave", "going to leave",
        "thought about leaving", "thinking about leaving", "almost left", "almost quit",
        "quit", "resign", "resigning", "burned out", "burnt out", "burning out",
        "another offer", "offer from", "recruiter", "poached", "interviewing",
    ]

    /// Words that count as the user engaging the statement.
    private static let engagementWords: Set<String> = [
        "leave", "leaving", "left", "stay", "staying", "quit", "resign",
        "burnout", "burned", "burnt", "offer", "recruiter", "interviewing",
        "why", "what happened", "tell me more",
    ]

    mutating func evaluate(_ input: SignalInput) -> Nudge? {
        guard input.speakerLabelsReliable else { return nil }
        guard input.elapsed - lastFired >= cooldown else { return nil }
        let turns = input.turns
        guard turns.count >= 2 else { return nil }

        // Look at recent Them turns whose engage-window has expired.
        for i in stride(from: turns.count - 1, through: max(0, turns.count - 6), by: -1) {
            let turn = turns[i]
            guard !turn.isYou, turn.speaker != "Meeting",
                  !firedTurnIDs.contains(turn.id),
                  input.elapsed - turn.endT >= engageWindowSeconds,
                  Self.tripwires.contains(where: { TextAnalysis.containsPhrase(turn.text, $0) })
            else { continue }

            // Did the user engage in any You turn after it?
            let engaged = turns[(i + 1)...].contains { later in
                later.isYou && !Self.engagementWords.isDisjoint(with: Set(TextAnalysis.words(later.text)))
            }
            firedTurnIDs.insert(turn.id)
            if engaged { continue }

            lastFired = input.elapsed
            return Nudge(
                id: UUID(),
                type: .buriedSignal,
                text: "They said something big — circle back",
                urgency: .high,
                timestamp: input.elapsed
            )
        }
        return nil
    }

    mutating func reset() {
        lastFired = -.infinity
        firedTurnIDs = []
    }
}
