import Foundation

/// Word-share talk statistics for the live meter: what fraction of the
/// conversation is you. Mirrors VoiceShareSignal's semantics (word counts
/// over turns, "Meeting" turns skipped — a mixed stream has no you/them
/// split until diarization labels it).
struct TalkStats: Sendable {
    /// Your share over the whole session (0…1). nil until there is enough
    /// labeled speech to be meaningful.
    var sessionShare: Double?
    /// Your share over the trailing window — what the meter emphasizes,
    /// since "the last five minutes" is what you can still change.
    var recentShare: Double?
    /// Sparkline samples: rolling share captured on a fixed cadence.
    var history: [Sample] = []

    struct Sample: Sendable, Identifiable {
        var id: TimeInterval { t }
        let t: TimeInterval
        let share: Double
    }

    var recentWindowSeconds: TimeInterval = 300
    /// Minimum labeled words before showing any number — a meter flapping
    /// on ten words reads as noise.
    var minWords: Int = 40
    private var lastSampleAt: TimeInterval = -.infinity
    private let sampleInterval: TimeInterval = 15

    /// Recompute from the current turn list. O(turns) per call, ~5s cadence.
    mutating func update(turns: [Turn], elapsed: TimeInterval) {
        var youTotal = 0, themTotal = 0
        var youRecent = 0, themRecent = 0
        let windowStart = elapsed - recentWindowSeconds

        for turn in turns {
            guard turn.isYou || turn.speaker != "Meeting" else { continue }
            if turn.isYou {
                youTotal += turn.wordCount
                if turn.endT >= windowStart { youRecent += turn.wordCount }
            } else {
                themTotal += turn.wordCount
                if turn.endT >= windowStart { themRecent += turn.wordCount }
            }
        }

        // No "You" turns at all means mic-only mode (structural labels are
        // "Meeting"/"Speaker N") — there is no your-share to measure, hide.
        let hasYou = youTotal > 0
        sessionShare = hasYou && youTotal + themTotal >= minWords
            ? Double(youTotal) / Double(youTotal + themTotal) : nil
        recentShare = hasYou && youRecent + themRecent >= minWords
            ? Double(youRecent) / Double(youRecent + themRecent) : nil

        if let share = recentShare ?? sessionShare,
           elapsed - lastSampleAt >= sampleInterval {
            history.append(Sample(t: elapsed, share: share))
            lastSampleAt = elapsed
        }
    }

    mutating func reset() {
        sessionShare = nil
        recentShare = nil
        history = []
        lastSampleAt = -.infinity
    }
}
