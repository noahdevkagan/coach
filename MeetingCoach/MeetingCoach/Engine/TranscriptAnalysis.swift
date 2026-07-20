import Foundation

// Shared transcript analysis: speaker turns and text heuristics.
//
// Signals reason over TURNS (coalesced same-speaker utterances), not raw ASR
// fragments. Fragment-level analysis was the biggest false-positive source:
// one spoken sentence arrives as several utterances, which inflated "turn"
// counts in every signal that walked the raw array.

// MARK: - Turn

/// A coalesced run of same-speaker utterances.
struct Turn: Identifiable {
    let id: UUID               // id of the first utterance — stable for SwiftUI
    let speaker: String
    let isYou: Bool
    var t: TimeInterval        // start of first utterance
    var endT: TimeInterval     // end of last utterance
    var text: String
    var wordCount: Int
    var utteranceCount: Int

    var formattedTime: String { mmss(t) }
}

/// Builds turns incrementally. Appending is O(1); a full rebuild is used when
/// the utterance array changed in a non-append way (rare out-of-order insert).
struct TurnBuilder {
    /// Same-speaker utterances separated by more than this gap start a new
    /// turn — a long silence is a real break, not one continuous thought.
    var maxJoinGap: TimeInterval = 10

    private(set) var turns: [Turn] = []

    mutating func append(_ u: Utterance) {
        let words = u.text.split(separator: " ").count
        if var last = turns.last,
           last.speaker == u.speaker,
           u.t - last.endT <= maxJoinGap {
            last.text += " " + u.text
            last.endT = max(last.endT, u.endT)
            last.wordCount += words
            last.utteranceCount += 1
            turns[turns.count - 1] = last
        } else {
            turns.append(Turn(
                id: u.id,
                speaker: u.speaker,
                isYou: u.isYou,
                t: u.t,
                endT: u.endT,
                text: u.text,
                wordCount: words,
                utteranceCount: 1
            ))
        }
    }

    mutating func rebuild(_ utterances: [Utterance]) {
        turns = []
        turns.reserveCapacity(utterances.count / 3 + 1)
        for u in utterances { append(u) }
    }

    mutating func reset() {
        turns = []
    }
}

// MARK: - Text analysis

enum TextAnalysis {

    /// Lowercase, fold smart quotes/apostrophes to ASCII, collapse whitespace.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }

    /// Tokenize into lowercase words, keeping in-word apostrophes ("i'll").
    static func words(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in normalize(s) {
            if ch.isLetter || ch.isNumber || ch == "'" {
                current.append(ch)
            } else if !current.isEmpty {
                result.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "'")))
                current = ""
            }
        }
        if !current.isEmpty {
            result.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "'")))
        }
        return result.filter { !$0.isEmpty }
    }

    /// Word-boundary phrase containment: "plan" does NOT match "airplane",
    /// and "i'll send" matches regardless of apostrophe style.
    static func containsPhrase(_ text: String, _ phrase: String) -> Bool {
        let haystack = " " + words(text).joined(separator: " ") + " "
        let needle = " " + words(phrase).joined(separator: " ") + " "
        return haystack.contains(needle)
    }

    // MARK: Questions

    /// Wh-words are strong question evidence as sentence starters.
    private static let whWords: Set<String> = [
        "what", "how", "why", "when", "where", "who", "which", "whose", "whom",
    ]
    /// Auxiliary starters are question evidence only when followed by a
    /// subject ("do you", "can we") — bare "will do" / "have a look" are not.
    private static let auxWords: Set<String> = [
        "could", "would", "should", "can", "do", "does", "did",
        "is", "are", "was", "were", "have", "has", "will", "shall", "am",
    ]
    private static let subjectWords: Set<String> = [
        "you", "we", "they", "i", "he", "she", "it", "there",
        "anyone", "anybody", "everyone", "this", "your", "that",
    ]

    /// Split into sentences on ./!/?, collapsing terminator runs ("??" = one),
    /// tagging whether the terminator run contained a question mark.
    static func sentences(_ text: String) -> [(text: String, questionMarked: Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "." || ch == "!" || ch == "?" {
                var questionMarked = ch == "?"
                var j = text.index(after: i)
                while j < text.endIndex, text[j] == "." || text[j] == "!" || text[j] == "?" {
                    if text[j] == "?" { questionMarked = true }
                    j = text.index(after: j)
                }
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append((trimmed, questionMarked)) }
                current = ""
                i = j
            } else {
                current.append(ch)
                i = text.index(after: i)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append((trimmed, false)) }
        return result
    }

    private static func isQuestionSentence(_ sentence: String, questionMarked: Bool) -> Bool {
        if questionMarked { return true }
        let w = words(sentence)
        guard let first = w.first else { return false }
        if whWords.contains(first) { return true }
        if auxWords.contains(first), w.count >= 2, subjectWords.contains(w[1]) { return true }
        return false
    }

    static func isQuestion(_ text: String) -> Bool {
        sentences(text).contains { isQuestionSentence($0.text, questionMarked: $0.questionMarked) }
    }

    static func questionCount(_ text: String) -> Int {
        sentences(text).filter { isQuestionSentence($0.text, questionMarked: $0.questionMarked) }.count
    }

    // MARK: Content words

    static let stopWords: Set<String> = [
        "i", "me", "my", "we", "our", "you", "your", "he", "she", "it", "they", "them",
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could", "should",
        "can", "may", "might", "shall", "to", "of", "in", "on", "at", "for", "with",
        "and", "or", "but", "not", "so", "if", "then", "than", "that", "this",
        "just", "like", "yeah", "yes", "no", "ok", "okay", "right", "well",
        "going", "gonna", "got", "get", "thing", "things", "think", "know",
        "really", "actually", "basically", "literally", "um", "uh",
    ]

    static func contentWords(_ text: String) -> Set<String> {
        Set(words(text).filter { $0.count > 1 && !stopWords.contains($0) })
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(union)
    }
}
