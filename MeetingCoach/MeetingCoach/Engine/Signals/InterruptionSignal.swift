import Foundation

/// Signal #10: Fires when user appears to cut off the other person mid-thought.
/// Detected as a short "Them" TURN (they never got going) where "You" started
/// speaking immediately after — or overlapping — their last words.
struct InterruptionSignal: SignalMonitor {
    let nudgeType: NudgeType = .interruption

    /// Max words in the Them turn to consider it a cut-off.
    var cutoffWordThreshold: Int = 6
    /// How many interruptions in a window before nudging.
    var interruptionThreshold: Int = 2
    /// Rolling window to count interruptions (seconds).
    var windowSeconds: TimeInterval = 180
    /// You must start within this many seconds of Them stopping.
    var takeoverGap: TimeInterval = 1.5
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 120

    private var lastFired: TimeInterval = -.infinity
    /// Only interruptions AFTER this time count — evidence that already
    /// produced a nudge must not re-fire when the cooldown lapses.
    private var evidenceAfter: TimeInterval = -.infinity

    mutating func evaluate(_ input: SignalInput) -> Nudge? {
        guard input.speakerLabelsReliable else { return nil }
        guard input.elapsed - lastFired >= cooldown else { return nil }
        let turns = input.turns
        guard turns.count >= 3 else { return nil }

        let windowStart = max(input.elapsed - windowSeconds, evidenceAfter)
        var interruptionCount = 0

        // Walk backwards; stop once we leave the window (turns are ordered).
        var i = turns.count - 1
        while i >= 1 {
            let prev = turns[i - 1]
            let curr = turns[i]
            if curr.t < windowStart { break }

            // Pattern: Them's whole turn was short AND looks cut off
            // mid-thought, and You took over immediately (or overlapped —
            // endT makes this a real overlap check). The cut-off check is
            // what separates a real interruption from a backchannel:
            // "Yeah. Okay." is complete; "But what about the—" is not.
            if !prev.isYou && prev.speaker != "Meeting" && curr.isYou
                && prev.wordCount <= cutoffWordThreshold
                && curr.t - prev.endT < takeoverGap
                && Self.looksCutOff(prev.text) {
                interruptionCount += 1
            }
            i -= 1
        }

        guard interruptionCount >= interruptionThreshold else { return nil }

        lastFired = input.elapsed
        evidenceAfter = input.elapsed
        return Nudge(
            id: UUID(),
            type: .interruption,
            text: "Let them finish",
            urgency: .high,
            timestamp: input.elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
        evidenceAfter = -.infinity
    }

    /// A turn that ended mid-thought: trails off ("…", "-", ",") or has no
    /// sentence-final punctuation at all. Both Zoom transcripts and live
    /// SFSpeech (addsPunctuation) punctuate complete sentences, so a missing
    /// terminator on a short turn is real evidence they didn't finish.
    static func looksCutOff(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        if last == "…" || last == "-" || last == "," { return true }
        if trimmed.hasSuffix("...") { return true }
        return !".!?".contains(last)
    }
}
