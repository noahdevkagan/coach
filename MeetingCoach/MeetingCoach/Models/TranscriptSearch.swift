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

    /// "session_2026-07-20_14-32.md" → "2026-07-20 14:32"
    static func title(for file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "session_", with: "")
        let parts = stem.split(separator: "_")
        guard parts.count == 2 else { return stem }
        return "\(parts[0]) \(parts[1].replacingOccurrences(of: "-", with: ":"))"
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
            let sessionTitle = title(for: file)
            var inSession = 0
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
