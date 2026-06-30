import Foundation

/// Signal #4: Fires when user repeats the same point/question within a short window.
/// Detects high content-word overlap between recent "You" utterances.
struct RepetitionLoopSignal: SignalMonitor {
    let nudgeType: NudgeType = .repetitionLoop

    /// How far back to look for repeated content (seconds).
    var windowSeconds: TimeInterval = 90
    /// Minimum Jaccard similarity to consider a repeat.
    var similarityThreshold: Double = 0.4
    /// Minimum seconds between fires.
    var cooldown: TimeInterval = 60
    /// Minimum content words in an utterance to even consider it.
    var minWords: Int = 3

    private var lastFired: TimeInterval = -.infinity

    private static let stopWords: Set<String> = [
        "i", "me", "my", "we", "our", "you", "your", "he", "she", "it", "they", "them",
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could", "should",
        "can", "may", "might", "shall", "to", "of", "in", "on", "at", "for", "with",
        "and", "or", "but", "not", "so", "if", "then", "than", "that", "this",
        "just", "like", "yeah", "yes", "no", "ok", "okay", "right", "well",
        "going", "gonna", "got", "get", "thing", "things", "think", "know",
        "really", "actually", "basically", "literally", "um", "uh",
    ]

    mutating func evaluate(utterances: [Utterance], elapsed: TimeInterval, context: PreCallContext) -> Nudge? {
        guard elapsed - lastFired >= cooldown else { return nil }

        let windowStart = elapsed - windowSeconds
        let recentYou = utterances.filter { $0.isYou && $0.t >= windowStart }
        guard recentYou.count >= 2 else { return nil }

        // Extract content words for each utterance
        let tokenized = recentYou.map { (utt: $0, words: Self.contentWords($0.text)) }
            .filter { $0.words.count >= minWords }
        guard tokenized.count >= 2 else { return nil }

        // Compare the latest utterance against all earlier ones in the window
        let latest = tokenized.last!
        for earlier in tokenized.dropLast() {
            let similarity = Self.jaccard(latest.words, earlier.words)
            if similarity >= similarityThreshold {
                lastFired = elapsed
                return Nudge(
                    id: UUID(),
                    type: .repetitionLoop,
                    text: "You already said this",
                    urgency: .med,
                    timestamp: elapsed
                )
            }
        }

        return nil
    }

    mutating func reset() {
        lastFired = -.infinity
    }

    // MARK: - Helpers

    static func contentWords(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) }
        return Set(words)
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return Double(intersection) / Double(union)
    }
}
