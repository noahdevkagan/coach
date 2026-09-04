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
    /// Budget tuned for speed (Noah, 2026-09-04: "a bit slow"): the answer
    /// only needs the best moments, and prompt length is what the user
    /// waits on — every 1k chars is ~250 tokens of prefill.
    static func buildContext(question: String,
                             dir: URL = AppSupport.sessionsDir,
                             maxSessions: Int = 3,
                             budget: Int = 7_000)
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
                .prefix(10)
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
                review: String(review.prefix(1_000)),
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

    /// Excerpts for a question about ONE open session (the in-session ask
    /// bar). Keyword-scored lines like the cross-session path; a question
    /// with no keyword hits ("how did this go?") falls back to an even
    /// sample so generic questions still see the whole meeting.
    static func sessionExcerpts(question: String,
                                transcriptLines: [String],
                                review: String,
                                budget: Int = 6_000) -> String {
        let words = keywords(in: question)
        var chosen: [String]
        let scored = transcriptLines.enumerated().map { i, line in
            (line: line,
             hits: words.filter {
                 line.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
             }.count,
             order: i)
        }
        let hitLines = scored.filter { $0.hits > 0 }
        if hitLines.isEmpty {
            let step = max(1, transcriptLines.count / 30)
            chosen = transcriptLines.enumerated()
                .filter { $0.offset % step == 0 }.map(\.element)
        } else {
            chosen = hitLines
                .sorted { $0.hits != $1.hits ? $0.hits > $1.hits : $0.order < $1.order }
                .prefix(24)
                .sorted { $0.order < $1.order }
                .map(\.line)
        }
        var parts: [String] = []
        var used = 0
        if !review.isEmpty {
            let notes = "Notes:\n" + String(review.prefix(1_200))
            parts.append(notes)
            used += notes.count
        }
        var moments: [String] = []
        for line in chosen {
            guard used + line.count <= budget else { break }
            used += line.count
            moments.append(line)
        }
        if !moments.isEmpty {
            parts.append("Transcript moments:\n" + moments.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Prompt for the in-session ask. Prior turns ride along so follow-ups
    /// ("what about the second one?") resolve against earlier answers.
    static func sessionPrompt(question: String, excerpts: String,
                              history: [(q: String, a: String)] = [])
        -> (system: String, user: String) {
        let system = """
        You answer questions about ONE meeting the user attended, using ONLY the meeting notes and transcript moments provided ("You" is the user).

        Rules:
        - Lead with the answer itself, not a preamble.
        - Prefer specifics from the excerpts: numbers, names, dates, decisions.
        - Lists go on "- " lines. Keep the whole reply under 150 words.
        - If the excerpts don't answer the question, say so in one sentence and name the closest thing they do contain. Never invent.
        - Plain text only: no markdown headers, bold, backticks, or tables.
        """
        var parts: [String] = []
        for turn in history {
            parts.append("Earlier question: \(turn.q)\nEarlier answer: \(turn.a)")
        }
        parts.append("Question: \(question)")
        parts.append("Meeting excerpts:\n\(excerpts)")
        parts.append("Answer the question now.")
        return (system, parts.joined(separator: "\n\n"))
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
