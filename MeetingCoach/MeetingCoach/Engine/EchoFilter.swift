import Foundation

/// Software acoustic-echo filter for the mic ("You") channel.
///
/// With voice processing off (see AudioCaptureManager.startMicrophone), the
/// far side's voice reaches the mic through the speakers, so mic chunks mix
/// the user's real speech with an echo of "Them". A whole-chunk overlap test
/// fails on that mix — a 30s mic chunk is rarely >60% echo overall even when
/// half of it is (measured on a real call: 3,771 of the far side's 5,016
/// words leaked into "You"). This filter works sentence-by-sentence instead.
///
/// Far-side words are pooled from streaming partials, not just commits: with
/// the system pipeline's longer silence gap, committed "Them" text can lag
/// the mic commit by many seconds, but partials arrive within ~1s of speech.
final class EchoFilter: @unchecked Sendable {
    /// Injectable time source — replay harnesses stamp pool entries with
    /// meeting time instead of wall clock.
    var clock: () -> Date = { Date() }

    private let lock = NSLock()
    private var entries: [(at: Date, words: [String])] = []
    private var lastPartialWords: [String] = []

    /// Longest mic chunk (30s) + commit lag, with slack.
    private let retention: TimeInterval = 45
    /// A sentence is echo when at least this fraction of its words were
    /// heard from the far side around the same time. High enough to spare
    /// genuine mirroring ("an inch in 46 minutes?"), low enough to absorb
    /// ASR divergence between the clean far stream and its acoustically
    /// degraded echo.
    private let overlapThreshold = 0.6
    /// 1-2 word sentences ("Yeah.", "Okay.") are said by both sides all the
    /// time — not classifiable as echo, always kept.
    private let minSentenceWords = 3

    /// Record a committed far-side utterance.
    func recordFarText(_ text: String) {
        let words = Self.words(text)
        guard !words.isEmpty else { return }
        lock.lock()
        append(words)
        lock.unlock()
    }

    /// Record a far-side partial. Partials re-send the whole growing window
    /// every tick, so only the words past the common prefix with the last
    /// partial are added (an empty partial means the window committed).
    /// Duplicates from re-transcription revisions are harmless — matching
    /// is set-based.
    func recordFarPartial(_ text: String) {
        let words = Self.words(text)
        lock.lock()
        defer { lock.unlock() }
        guard !words.isEmpty else {
            lastPartialWords = []
            return
        }
        var i = 0
        while i < min(words.count, lastPartialWords.count), words[i] == lastPartialWords[i] {
            i += 1
        }
        let fresh = Array(words[i...])
        lastPartialWords = words
        if !fresh.isEmpty { append(fresh) }
    }

    /// Remove echoed sentences from a mic transcription. `since` bounds the
    /// far-side pool to words heard during this chunk (echo is simultaneous
    /// with the far speech, so anything older can't be its source).
    ///
    /// Returns nil when every sentence is echo (drop the utterance), or the
    /// surviving text plus the fraction of words kept — callers scale the
    /// utterance's duration by it so talk-time isn't credited for the far
    /// side's speech.
    func filter(_ text: String, since: Date) -> (text: String, keptFraction: Double)? {
        lock.lock()
        let pool = Set(entries.lazy.filter { $0.at >= since }.flatMap(\.words))
        lock.unlock()
        guard !pool.isEmpty else { return (text, 1.0) }

        let sentences = Self.sentences(text)
        var kept: [String] = []
        var keptWords = 0
        var totalWords = 0
        for sentence in sentences {
            let ws = Self.words(sentence)
            totalWords += ws.count
            if ws.count >= minSentenceWords {
                let matched = ws.filter(pool.contains).count
                if Double(matched) / Double(ws.count) >= overlapThreshold { continue }
            }
            kept.append(sentence)
            keptWords += ws.count
        }
        guard !kept.isEmpty, keptWords > 0 else { return nil }
        if kept.count == sentences.count { return (text, 1.0) }
        return (kept.joined(separator: " "), Double(keptWords) / Double(totalWords))
    }

    private func append(_ words: [String]) {
        entries.append((clock(), words))
        let cutoff = clock().addingTimeInterval(-retention)
        if let first = entries.first, first.at < cutoff {
            entries.removeAll { $0.at < cutoff }
        }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "…" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { out.append(trimmed) }
        return out
    }
}
