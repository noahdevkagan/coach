import Foundation

/// One matched transcript moment from a saved session.
struct TranscriptHit: Identifiable, Sendable {
    let id = UUID()
    let file: URL
    let sessionTitle: String
    let timestamp: String   // call-relative "mm:ss" from the saved line
    let speaker: String     // "You" / "Them" / recognizer label
    let text: String        // the spoken line (bullet and stamp stripped)
}

/// Case-insensitive full-text search over saved sessions
/// (AppSupport.sessionsDir, session_*.md). Foundation-only on purpose: the
/// MCP server target compiles this exact file standalone, so in-app search
/// and agent search can never drift.
enum TranscriptSearch {
    /// Saved sessions, newest first — the filename stamp
    /// (session_yyyy-MM-dd_HH-mm.md) sorts naturally.
    static func sessionFiles(in dir: URL = AppSupport.sessionsDir) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return items
            .filter { $0.lastPathComponent.hasPrefix("session_") && $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// "session_2026-07-20_14-32.md" → "Jul 20, 2:32 PM". The raw
    /// "2026-07-20 14:32" fallback read like a filename in the sessions
    /// list (Noah, 2026-08-04); every consumer is a display surface.
    static func title(for file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "session_", with: "")
        let parse = DateFormatter()
        parse.dateFormat = "yyyy-MM-dd_HH-mm"
        guard let date = parse.date(from: stem) else {
            return stem.replacingOccurrences(of: "_", with: " ")
        }
        let out = DateFormatter()
        out.dateFormat = "MMM d, h:mm a"
        return out.string(from: date)
    }

    /// "session_2026-07-20_14-32.md" → "Jul 20" — the compact date shown
    /// next to a session's title. Nil when the filename isn't date-stamped.
    static func shortDate(for file: URL) -> String? {
        let stem = file.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "session_", with: "")
        guard let day = stem.split(separator: "_").first else { return nil }
        let parse = DateFormatter()
        parse.dateFormat = "yyyy-MM-dd"
        guard let date = parse.date(from: String(day)) else { return nil }
        let out = DateFormatter()
        out.dateFormat = "MMM d"
        return out.string(from: date)
    }

    /// User-facing title: the "**Title:** …" header line when present
    /// (person · subject, written at save time or via rename), else the
    /// filename date.
    static func displayTitle(for file: URL) -> String {
        if let content = try? String(contentsOf: file, encoding: .utf8),
           let header = headerTitle(in: content) {
            return header
        }
        return title(for: file)
    }

    /// Parse the "**Title:** …" line from a session file's header block
    /// (stops at the first "## " section — the title never lives past it).
    static func headerTitle(in content: String) -> String? {
        for line in content.components(separatedBy: "\n").prefix(16) {
            if line.hasPrefix("**Title:**") {
                let t = line.dropFirst("**Title:**".count)
                    .trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : t
            }
            if line.hasPrefix("## ") { break }
        }
        return nil
    }

    static func headerTitle(at file: URL) -> String? {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return headerTitle(in: content)
    }

    /// Everyday conversation words that carry no topic. Aggressive on
    /// purpose — a wrong topic word in a title is worse than a shorter title.
    private static let titleStopWords: Set<String> = [
        "that", "this", "with", "have", "just", "like", "know", "think",
        "going", "really", "actually", "right", "yeah", "okay", "want",
        "need", "well", "good", "great", "time", "meeting", "thing",
        "things", "stuff", "kind", "sort", "maybe", "probably", "gonna",
        "little", "mean", "look", "guys", "cool", "sure", "thanks", "thank",
        "there", "here", "what", "when", "where", "which", "would", "could",
        "should", "will", "been", "being", "were", "them", "they", "their",
        "your", "yours", "from", "into", "about", "because", "then", "than",
        "some", "something", "someone", "anything", "everything", "other",
        "over", "back", "down", "much", "more", "most", "very", "also",
        "make", "makes", "made", "making", "take", "takes", "took", "come",
        "comes", "came", "week", "today", "tomorrow", "said", "says", "tell",
        "talk", "talking", "point", "does", "doesn", "didn", "don", "isn",
        "aren", "wasn", "won", "can", "cant", "couldn", "wouldn", "shouldn",
        "haven", "hasn", "hadn", "getting", "gets", "give", "gives", "still",
        "even", "only", "work", "works", "working", "people", "person",
        "first", "last", "next", "years", "year", "months", "month", "days",
        "hours", "hour", "minutes", "minute", "questions", "question",
        // Generic gerunds and comparatives — verbs about talking, never
        // the topic being talked about.
        "these", "those", "doing", "done", "going", "being", "saying",
        "seeing", "getting", "making", "taking", "coming", "looking",
        "talking", "thinking", "trying", "tried", "using", "having",
        "putting", "trying", "better", "best", "worse", "easier", "harder",
        "bigger", "smaller", "plus", "whatever", "whether", "every",
        "always", "never", "though", "anyway", "basically", "literally",
        "honestly", "obviously", "different", "important", "interesting",
        "definitely", "totally", "exactly", "somebody", "everybody",
        "anybody", "nothing", "nobody", "somewhere", "pretty", "kinda",
        "sorta", "wanna", "lets", "feel", "feels", "felt", "guess", "else",
        "start", "started", "starting", "stop", "stopped", "ways", "says",
        "yeah", "yes", "okay", "sense", "whole", "half", "part", "parts",
        "least", "less", "lots", "many", "real", "true", "wrong", "long",
        "short", "high", "higher", "lower", "another", "again", "around",
        "through", "before", "after", "while", "during", "without",
    ]

    /// Capitalized tokens that are never names: function words ASR
    /// capitalizes at clause starts, calendar words, interjections, and
    /// product names common in this corpus.
    private static let nameBlocklist: Set<String> = [
        "and", "but", "because", "since", "while", "what", "when", "where",
        "which", "who", "whom", "how", "why", "you", "your", "they", "them",
        "their", "she", "him", "her", "his", "hers", "its", "was", "were",
        "are", "is", "the", "for", "with", "from", "then", "than", "that",
        "this", "these", "those", "there", "here", "not", "now", "just",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday", "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
        "okay", "yeah", "yes", "no", "alright", "sorry", "cool", "right",
        "gotcha", "awesome", "thanks", "thank", "hey", "hi", "hello", "bye",
        "guys", "everyone", "team", "man", "dude", "buddy", "god", "wow",
        "morning", "afternoon", "tonight", "today", "tomorrow", "yesterday",
        "zoom", "google", "slack", "notion", "apple", "amazon", "meet",
        "chat", "gmail", "claude", "chatgpt", "ollama", "anthropic",
    ]

    /// Best guess at who the meeting was with: capitalized mid-utterance
    /// tokens scored across the transcript, vocatives ("Hey Caitlin",
    /// "…, Sean?") weighted 3×. Nil below a small floor — no name beats a
    /// wrong name. Heuristic by design; rename always overrides.
    static func chattedWithName(in content: String) -> String? {
        let greetings: Set<String> = ["hey", "hi", "hello", "thanks",
                                      "morning", "afternoon", "welcome"]
        var scores: [String: Int] = [:]
        for rawLine in content.split(separator: "\n") {
            guard let line = parseTranscriptLine(String(rawLine)) else { continue }
            let tokens = line.text.split(separator: " ")
            for (i, tok) in tokens.enumerated() {
                // Sentence-start capitals are noise, not names.
                guard i > 0 else { continue }
                let t = tok.trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:'\""))
                guard (3...12).contains(t.count),
                      let first = t.first, first.isUppercase,
                      t.dropFirst().allSatisfy({ $0.isLowercase && $0.isLetter })
                else { continue }
                let lower = t.lowercased()
                guard !nameBlocklist.contains(lower), !titleStopWords.contains(lower)
                else { continue }
                let prev = String(tokens[i - 1])
                let vocative = greetings.contains(
                    prev.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:")))
                    || (prev.hasSuffix(",")
                        && (tok.hasSuffix(".") || tok.hasSuffix("?") || tok.hasSuffix("!")
                            || i == tokens.count - 1))
                scores[t, default: 0] += vocative ? 3 : 1
            }
        }
        let best = scores.max {
            $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
        }
        guard let best, best.value >= 4 else { return nil }
        return best.key
    }

    /// Deterministic title suggestion for a session that has no header
    /// title: the person the meeting was with (when one is detectable) plus
    /// the most-discussed topic words, e.g. "Caitlin · pricing & renewal".
    /// Nil when the transcript is too thin to name honestly (the date is
    /// better than a made-up title).
    static func suggestedTitle(in content: String) -> String? {
        var counts: [String: Int] = [:]
        var order: [String: Int] = [:]   // first-seen order for stable ties
        var lineCount = 0
        for rawLine in content.split(separator: "\n") {
            guard let line = parseTranscriptLine(String(rawLine)) else { continue }
            lineCount += 1
            for raw in line.text.split(whereSeparator: { !$0.isLetter }) {
                let word = raw.lowercased()
                guard word.count >= 4, !titleStopWords.contains(word) else { continue }
                counts[word, default: 0] += 1
                if order[word] == nil { order[word] = lineCount }
            }
        }
        // A topic must recur to count — 3 mentions minimum, scaled up for
        // long sessions so one anecdote can't name the meeting.
        let minCount = max(3, lineCount / 150)
        let name = chattedWithName(in: content)
        var words = Array(
            counts.filter { $0.value >= minCount }
                .sorted {
                    $0.value != $1.value ? $0.value > $1.value
                        : order[$0.key, default: .max] < order[$1.key, default: .max]
                }
                // With a name the topics are a subtitle — two is plenty.
                .prefix(name == nil ? 3 : 2)
                .map(\.key)
        )
        if let name {
            guard !words.isEmpty else { return name }
            return "\(name) · \(words.joined(separator: " & "))"
        }
        guard !words.isEmpty else { return nil }
        words[0] = words[0].prefix(1).uppercased() + words[0].dropFirst()
        switch words.count {
        case 1: return words[0]
        case 2: return "\(words[0]) & \(words[1])"
        default: return "\(words[0]), \(words[1]) & \(words[2])"
        }
    }

    /// A Title line exists at all — even an empty one. An empty line is the
    /// "user cleared the title, show the date" sentinel: removing the line
    /// instead would make the sidebar's auto-titler re-suggest a topic
    /// title on the next reload, silently undoing the clear.
    static func hasTitleLine(in content: String) -> Bool {
        for line in content.components(separatedBy: "\n").prefix(16) {
            if line.hasPrefix("**Title:**") { return true }
            if line.hasPrefix("## ") { break }
        }
        return false
    }

    /// Rename a session: write (or, when cleared, blank out) the Title
    /// header line. The date-based filename is untouched — it's the sort
    /// key and is parsed for the session date.
    /// Adopt a generated (LLM review) title unless a human or a real
    /// meeting name got there first. Machine titles are reproducible: a
    /// header title that matches what `suggestedTitle` would produce for
    /// this content was machine-written by the sidebar, so upgrading it
    /// loses nothing. Anything else (rename, window title, pre-call
    /// person·subject) wins, and a bare Title line is the user's
    /// cleared-title sentinel — the date stays.
    static func adoptGeneratedTitle(_ title: String, for file: URL) {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return }
        if let current = headerTitle(in: content) {
            guard current == suggestedTitle(in: content) else { return }
        } else if hasTitleLine(in: content) {
            return
        }
        setTitle(title, for: file)
    }

    static func setTitle(_ title: String, for file: URL) {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return }
        var lines = content.components(separatedBy: "\n")
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = lines.firstIndex(where: { $0.hasPrefix("**Title:**") }) {
            // Cleared: keep a bare "**Title:**" marker (see hasTitleLine).
            lines[i] = cleaned.isEmpty ? "**Title:**" : "**Title:** \(cleaned)"
        } else if !cleaned.isEmpty {
            let insertAt = lines.firstIndex(where: { $0.hasPrefix("# ") })
                .map { lines.index(after: $0) } ?? 0
            lines.insert("**Title:** \(cleaned)", at: insertAt)
        }
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// Search the spoken lines of every saved session. Matches only against
    /// what was said — headers and stats would make every query noisy.
    /// Queries under 2 characters return nothing (too noisy to be useful).
    static func search(_ query: String,
                       in dir: URL = AppSupport.sessionsDir,
                       maxPerSession: Int = 8,
                       limit: Int = 60) -> [TranscriptHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }

        var hits: [TranscriptHit] = []
        for file in sessionFiles(in: dir) {
            guard hits.count < limit,
                  let content = try? String(contentsOf: file, encoding: .utf8)
            else { continue }
            let sessionTitle = headerTitle(in: content) ?? title(for: file)
            var inSession = 0
            // A title match surfaces the session even when the words were
            // never spoken — meeting names ("Cal · tidy & affiliate",
            // "Weekly Sync") are how people remember sessions, and titles
            // aren't transcript lines so the loop below can't see them.
            if sessionTitle.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                hits.append(TranscriptHit(file: file, sessionTitle: sessionTitle,
                                          timestamp: "", speaker: "",
                                          text: sessionTitle))
                inSession += 1
            }
            for rawLine in content.split(separator: "\n") {
                guard inSession < maxPerSession, hits.count < limit else { break }
                guard let line = parseTranscriptLine(String(rawLine)),
                      line.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                else { continue }
                hits.append(TranscriptHit(file: file, sessionTitle: sessionTitle,
                                          timestamp: line.stamp, speaker: line.speaker,
                                          text: line.text))
                inSession += 1
            }
        }
        return hits
    }

    /// Saved transcript lines look like "- [12:41] You: we should ship it".
    /// Anything else (headers, stats, nudge lists) parses to nil.
    static func parseTranscriptLine(_ line: String) -> (stamp: String, speaker: String, text: String)? {
        guard line.hasPrefix("- ["), let close = line.firstIndex(of: "]") else { return nil }
        let stamp = String(line[line.index(line.startIndex, offsetBy: 3)..<close])
        let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let speaker = String(rest[..<colon])
        let text = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !speaker.isEmpty, speaker.count < 40 else { return nil }
        return (stamp, speaker, text)
    }
}
