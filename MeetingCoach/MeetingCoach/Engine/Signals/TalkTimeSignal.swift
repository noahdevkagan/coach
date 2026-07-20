import Foundation

/// Signal #1: Fires when user holds the floor > threshold seconds continuously.
struct TalkTimeSignal: SignalMonitor {
    let nudgeType: NudgeType = .talkTime

    /// Continuous "You" speaking time before firing (seconds).
    var threshold: TimeInterval = 30
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 45
    /// Max silence after the turn's last words before the streak breaks.
    var maxGap: TimeInterval = 10

    private var lastFired: TimeInterval = -.infinity

    mutating func evaluate(_ input: SignalInput) -> Nudge? {
        guard input.elapsed - lastFired >= cooldown else { return nil }
        // Floor-hogging needs a floor to hog: until someone else has said
        // anything, this is pre-meeting chatter to an empty room (waiting
        // for the other side to join), not a monologue.
        guard input.turns.contains(where: { !$0.isYou }) else { return nil }
        // TurnBuilder already breaks turns on >10s silences, so the last turn
        // IS the current streak. Require it to still be live (not trailed off).
        guard let turn = input.turns.last, turn.isYou else { return nil }
        guard input.elapsed - turn.endT <= maxGap else { return nil }

        let continuousTime = input.elapsed - turn.t
        guard continuousTime >= threshold else { return nil }

        lastFired = input.elapsed
        return Nudge(
            id: UUID(),
            type: .talkTime,
            text: "You're still talking",
            urgency: .high,
            timestamp: input.elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
    }
}
