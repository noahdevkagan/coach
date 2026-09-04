import Foundation

/// One meeting an answer drew from — enough to render a source row and
/// open the session.
struct MeetingAskSource: Identifiable, Equatable {
    var id: URL { file }
    let file: URL
    let title: String
    /// "Sep 3" — empty when the filename carries no date stamp.
    let date: String
}

/// "Ask your meetings": turn a question into retrieval over the saved
/// sessions, and the retrieved excerpts into a local-LLM prompt. This type
/// is deliberately pure (no Ollama, no UI) — SearchResultsView owns the
/// model lifecycle, exactly like SessionDetailView does for the review.
enum MeetingAsk {

    /// The content words of a question: lowercase alphanumeric runs, 3+
    /// chars, minus everyday stopwords. Falls back to the raw words when
    /// the whole question is stopwords ("what did we do?") so retrieval
    /// still has something to hold onto.
    static func keywords(in question: String) -> [String] {
        let raw = question.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        var seen = Set<String>()
        let content = raw.filter {
            $0.count >= 3 && !TranscriptSearch.titleStopWords.contains($0)
                && seen.insert($0).inserted
        }
        if !content.isEmpty { return content }
        seen.removeAll()
        return raw.filter { $0.count >= 3 && seen.insert($0).inserted }
    }

    /// Retrieval: score every saved session by how many of the question's
    /// words it contains (distinct coverage dominates raw hit count, recency
    /// breaks ties), then build the excerpt block the LLM answers from —
    /// per selected session, its saved review (dense, already summarized)
    /// plus the matching transcript lines. Pure and deterministic.
    static func buildContext(question: String,
                             dir: URL = AppSupport.sessionsDir,
                             maxSessions: Int = 4,
                             budget: Int = 12_000)
        -> (excerpts: String, sources: [MeetingAskSource]) {
        let words = keywords(in: question)
        guard !words.isEmpty else { return ("", []) }

        struct Candidate {
            let file: URL
            let title: String
            let date: String
            let review: String
            let matchedLines: [String]
            let distinct: Int
        }

        var candidates: [Candidate] = []
        // Newest-first is the tiebreak: sessionFiles already sorts by the
        // filename date stamp. 60 files ≈ months of meetings; enough.
        for file in TranscriptSearch.sessionFiles(in: dir).prefix(60) {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var matched: Set<String> = []
            var scored: [(text: String, hits: Int, order: Int)] = []
            var reviewLines: [String] = []
            var inReview = false
            for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
                let raw = String(rawLine)
                if raw.hasPrefix("## ") {
                    inReview = raw.hasPrefix("## Review")
                    continue
                }
                if inReview {
                    reviewLines.append(raw)
                    continue
                }
                guard let line = TranscriptSearch.parseTranscriptLine(raw) else { continue }
                var hits = 0
                for word in words where line.text.range(
                    of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    matched.insert(word)
                    hits += 1
                }
                if hits > 0 {
                    scored.append(("[\(line.stamp)] \(line.speaker): \(line.text)",
                                   hits, scored.count))
                }
            }
            // The 14 best moments, not the 14 first: a long meeting says a
            // common word ("team") constantly, and first-come filled the
            // cap before the lines that hit several question words at once.
            // Re-sorted by position afterwards so the excerpt reads in
            // meeting order.
            let lines = scored
                .sorted { $0.hits != $1.hits ? $0.hits > $1.hits : $0.order < $1.order }
                .prefix(14)
                .sorted { $0.order < $1.order }
                .map(\.text)
            // The review text counts for coverage too — a topic can live
            // in the notes ("565 agency: fire first") in words the raw
            // transcript garbled.
            let review = reviewLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for word in words where review.range(
                of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                matched.insert(word)
            }
            guard !matched.isEmpty else { continue }
            let title = TranscriptSearch.headerTitle(in: content)
                ?? TranscriptSearch.title(for: file)
            candidates.append(Candidate(
                file: file, title: title,
                date: TranscriptSearch.shortDate(for: file) ?? "",
                review: String(review.prefix(1_500)),
                matchedLines: lines,
                distinct: matched.count))
        }

        // Coverage beats volume: a session containing all the question's
        // words outranks one that says a single word fifty times. Stable
        // sort keeps newest-first within a coverage tier.
        let picked = candidates.enumerated()
            .sorted {
                $0.element.distinct != $1.element.distinct
                    ? $0.element.distinct > $1.element.distinct
                    : $0.offset < $1.offset
            }
            .prefix(maxSessions)
            .map(\.element)

        var blocks: [String] = []
        var used = 0
        var sources: [MeetingAskSource] = []
        for c in picked {
            var block = "— Meeting: \(c.title)"
            if !c.date.isEmpty { block += " (\(c.date))" }
            if !c.review.isEmpty { block += "\nNotes:\n\(c.review)" }
            if !c.matchedLines.isEmpty {
                block += "\nTranscript moments:\n" + c.matchedLines.joined(separator: "\n")
            }
            guard used + block.count <= budget else { break }
            used += block.count
            blocks.append(block)
            sources.append(MeetingAskSource(file: c.file, title: c.title, date: c.date))
        }
        return (blocks.joined(separator: "\n\n"), sources)
    }

    /// The answer prompt. Excerpt-grounded on purpose: the model may only
    /// synthesize what retrieval found, and must say when that isn't enough.
    static func prompt(question: String, excerpts: String) -> (system: String, user: String) {
        let system = """
        You answer a question about the user's own past meetings, using ONLY the meeting excerpts provided. The excerpts are notes and transcript moments from the user's locally saved sessions ("You" is the user).

        Rules:
        - Lead with the answer itself, not a preamble.
        - Prefer specifics that appear in the excerpts: numbers, names, dates, decisions.
        - Lists go on "- " lines. Keep the whole reply under 180 words.
        - When facts come from different meetings, say which meeting (its title and date) inline.
        - If the excerpts don't answer the question, say so in one sentence and name the closest thing they do contain. Never invent.
        - Plain text only: no markdown headers, bold, backticks, or tables.
        """
        let user = """
        Question: \(question)

        Meeting excerpts (best matches first):
        \(excerpts)

        Answer the question now.
        """
        return (system, user)
    }
}
