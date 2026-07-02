import Foundation

/// Signal #4: Fires when user repeats the same point/question within a short window.
/// Detects high content-word overlap between recent "You" turns.
struct RepetitionLoopSignal: SignalMonitor {
    let nudgeType: NudgeType = .repetitionLoop

    /// How far back to look for repeated content (seconds).
    var windowSeconds: TimeInterval = 90
    /// Minimum Jaccard similarity to consider a repeat.
    var similarityThreshold: Double = 0.4
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 60
    /// Minimum content words in a turn to even consider it.
    var minWords: Int = 3

    private var lastFired: TimeInterval = -.infinity
    /// Content-word sets that already produced a nudge. The same repetition
    /// sitting in the window must not re-fire every cooldown.
    private var firedContent: [Set<String>] = []
    /// Token cache keyed by turn id; invalidated when the turn grows.
    private var tokenCache: [UUID: (wordCount: Int, words: Set<String>)] = [:]

    mutating func evaluate(_ input: SignalInput) -> Nudge? {
        guard input.elapsed - lastFired >= cooldown else { return nil }

        let windowStart = input.elapsed - windowSeconds
        var recentYou: [Turn] = []
        for turn in input.turns.reversed() {
            if turn.endT < windowStart { break }
            if turn.isYou { recentYou.insert(turn, at: 0) }
        }
        guard recentYou.count >= 2 else { return nil }

        // Prune cache entries that fell out of the window
        let liveIDs = Set(recentYou.map(\.id))
        tokenCache = tokenCache.filter { liveIDs.contains($0.key) }

        // Tokenize (cached per turn until it grows)
        var tokenized: [(turn: Turn, words: Set<String>)] = []
        for turn in recentYou {
            let words: Set<String>
            if let cached = tokenCache[turn.id], cached.wordCount == turn.wordCount {
                words = cached.words
            } else {
                words = TextAnalysis.contentWords(turn.text)
                tokenCache[turn.id] = (turn.wordCount, words)
            }
            if words.count >= minWords {
                tokenized.append((turn, words))
            }
        }
        guard tokenized.count >= 2 else { return nil }

        // Compare the latest turn against all earlier ones in the window
        let latest = tokenized.last!

        // Evidence latch: skip if this content already produced a nudge
        guard !firedContent.contains(where: {
            TextAnalysis.jaccard(latest.words, $0) >= similarityThreshold
        }) else { return nil }

        for earlier in tokenized.dropLast() {
            let similarity = TextAnalysis.jaccard(latest.words, earlier.words)
            if similarity >= similarityThreshold {
                lastFired = input.elapsed
                firedContent.append(latest.words)
                if firedContent.count > 10 { firedContent.removeFirst() }
                return Nudge(
                    id: UUID(),
                    type: .repetitionLoop,
                    text: "You already said this",
                    urgency: .med,
                    timestamp: input.elapsed
                )
            }
        }

        return nil
    }

    mutating func reset() {
        lastFired = -.infinity
        firedContent = []
        tokenCache = [:]
    }
}
