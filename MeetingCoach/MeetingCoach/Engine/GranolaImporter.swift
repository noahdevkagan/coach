import Foundation

/// One-click import of Granola meeting history into MeetingCoach sessions.
///
/// Primary path reads Granola's local cache directly (the app is not
/// sandboxed): `~/Library/Application Support/Granola/cache-v3.json` is
/// JSON whose `cache` key holds a second JSON document *as a string*;
/// inside that, `state.documents` carries the notes and
/// `state.transcripts` the (recently viewed) transcripts. Newer Granola
/// versions encrypt this cache — that surfaces as `.unreadableCache` and
/// the Settings UI falls back to importing files Granola exported.
///
/// Imported sessions are ordinary `session_yyyy-MM-dd_HH-mm.md` files in
/// the transcripts folder, stamped with the meeting's ORIGINAL date (the
/// filename is the only date the dashboard/search parsers read), and carry
/// an `**Imported-From:**` header line as the re-import dedupe marker.
enum GranolaImporter {
    struct Report: Sendable {
        var imported = 0
        var skippedExisting = 0
        var skippedNoDate = 0

        var summary: String {
            var parts = ["Imported \(imported) meeting\(imported == 1 ? "" : "s")"]
            if skippedExisting > 0 { parts.append("\(skippedExisting) already imported") }
            if skippedNoDate > 0 { parts.append("\(skippedNoDate) skipped (no date)") }
            return parts.joined(separator: " · ")
        }
    }

    enum ImportError: LocalizedError {
        case notInstalled
        case unreadableCache

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Granola doesn't appear to be installed on this Mac."
            case .unreadableCache:
                return "Granola's local data is encrypted or in a newer format — import files exported from Granola instead."
            }
        }
    }

    static var granolaDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Granola", isDirectory: true)
    }

    static var cacheURL: URL {
        granolaDir.appendingPathComponent("cache-v3.json")
    }

    // MARK: - Cache import

    static func importFromCache(into dir: URL = AppSupport.sessionsDir) throws -> Report {
        let fm = FileManager.default
        guard fm.fileExists(atPath: granolaDir.path) else { throw ImportError.notInstalled }
        guard let raw = try? Data(contentsOf: cacheURL) else { throw ImportError.unreadableCache }

        // Double-encoded: top-level { "cache": "<json string>" }.
        guard let top = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let inner = top["cache"] as? String,
              let innerData = inner.data(using: .utf8),
              let cache = (try? JSONSerialization.jsonObject(with: innerData)) as? [String: Any],
              let state = cache["state"] as? [String: Any]
        else { throw ImportError.unreadableCache }

        // Documents ship either keyed by id or as a plain array.
        var documents: [[String: Any]] = []
        if let dict = state["documents"] as? [String: [String: Any]] {
            documents = Array(dict.values)
        } else if let array = state["documents"] as? [[String: Any]] {
            documents = array
        } else {
            throw ImportError.unreadableCache
        }

        let transcripts = state["transcripts"] as? [String: Any] ?? [:]
        let existing = existingImportMarkers(in: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var report = Report()
        for doc in documents {
            guard let id = doc["id"] as? String else { continue }
            if existing.contains("granola:\(id)") {
                report.skippedExisting += 1
                continue
            }

            let notes = (doc["notes_markdown"] as? String)
                ?? (doc["notes_plain"] as? String) ?? ""
            let transcriptLines = transcriptLines(from: transcripts[id])
            // Nothing to bring over — not worth a file (or a report line).
            guard !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !transcriptLines.isEmpty else { continue }

            let calendar = doc["google_calendar_event"] as? [String: Any]
            guard let start = isoDate(nested(calendar, "start", "dateTime"))
                ?? isoDate(doc["created_at"] as? String) else {
                // A wrong date in a date-keyed archive is worse than absence.
                report.skippedNoDate += 1
                continue
            }
            let end = isoDate(nested(calendar, "end", "dateTime"))

            let title = (doc["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            write(marker: "granola:\(id)", title: title, date: start,
                  duration: end.map { $0.timeIntervalSince(start) },
                  notes: notes, transcriptLines: transcriptLines, into: dir)
            report.imported += 1
        }
        return report
    }

    /// Best-effort transcript extraction — Granola only caches transcripts
    /// for recently viewed meetings, and the segment shape is theirs to
    /// change, so every field read is defensive and absence is fine.
    private static func transcriptLines(from value: Any?) -> [String] {
        guard let segments = value as? [[String: Any]], !segments.isEmpty else { return [] }
        let firstStamp = segments.lazy
            .compactMap { isoDate($0["start_timestamp"] as? String) }
            .first
        var lines: [String] = []
        for segment in segments {
            guard let text = (segment["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let speaker = (segment["source"] as? String) == "microphone" ? "You" : "Them"
            var offset: TimeInterval = 0
            if let firstStamp, let stamp = isoDate(segment["start_timestamp"] as? String) {
                offset = max(0, stamp.timeIntervalSince(firstStamp))
            }
            lines.append("- [\(mmss(offset))] \(speaker): \(text)")
        }
        return lines
    }

    // MARK: - Exported-file import (fallback for encrypted caches)

    static func importExportedFiles(_ urls: [URL], into dir: URL = AppSupport.sessionsDir) -> Report {
        let existing = existingImportMarkers(in: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var report = Report()
        for url in urls {
            let marker = "granola-file:\(url.lastPathComponent)"
            if existing.contains(marker) {
                report.skippedExisting += 1
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let lines = text.components(separatedBy: .newlines)
            let title = lines.first { $0.hasPrefix("# ") }
                .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
                ?? url.deletingPathExtension().lastPathComponent

            // Meeting date: first ISO-ish date in the head of the file,
            // else the file's own creation date.
            var date = lines.prefix(10).lazy.compactMap(Self.dateInLine).first
            if date == nil {
                date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            }
            guard let date else {
                report.skippedNoDate += 1
                continue
            }

            write(marker: marker, title: title, date: date, duration: nil,
                  notes: text, transcriptLines: [], into: dir)
            report.imported += 1
        }
        return report
    }

    // MARK: - Session file writing

    private static func write(marker: String, title: String, date: Date,
                              duration: TimeInterval?, notes: String,
                              transcriptLines: [String], into dir: URL) {
        let stampFormatter = DateFormatter()
        stampFormatter.dateFormat = "yyyy-MM-dd_HH-mm"

        // The filename IS the session date for every parser — collisions
        // bump forward a minute rather than adding a suffix that would make
        // the file invisible to the dashboard.
        var slot = date
        var file = dir.appendingPathComponent("session_\(stampFormatter.string(from: slot)).md")
        var tries = 0
        while FileManager.default.fileExists(atPath: file.path), tries < 59 {
            slot = slot.addingTimeInterval(60)
            file = dir.appendingPathComponent("session_\(stampFormatter.string(from: slot)).md")
            tries += 1
        }
        guard !FileManager.default.fileExists(atPath: file.path) else { return }

        var lines: [String] = []
        lines.append("# Meeting Coach Session — \(stampFormatter.string(from: slot))")
        if !title.isEmpty {
            lines.append("**Title:** \(title)")
        }
        if let duration, duration > 0 {
            let total = Int(duration)
            lines.append("**Duration:** \(String(format: "%02d:%02d", total / 60, total % 60))")
        }
        lines.append("**Utterances:** \(transcriptLines.count)")
        lines.append("**Nudges:** 0")
        lines.append("**Engine:** Granola import")
        lines.append("**Imported-From:** \(marker)")
        lines.append("")

        let cleanedNotes = sanitizeNotes(notes)
        if !cleanedNotes.isEmpty {
            lines.append("## Imported Notes")
            lines.append(cleanedNotes)
            lines.append("")
        }
        if !transcriptLines.isEmpty {
            lines.append("## Transcript")
            lines.append(contentsOf: transcriptLines)
            lines.append("")
        }

        try? lines.joined(separator: "\n")
            .write(to: file, atomically: true, encoding: .utf8)
    }

    /// Notes bodies get two adjustments so the session parsers can't
    /// misread them: task checkboxes ("- [ ] Send deck") would parse as
    /// transcript lines, and a "## Nudges" heading would trip the nudge
    /// counter. Content is otherwise untouched.
    static func sanitizeNotes(_ notes: String) -> String {
        notes.components(separatedBy: .newlines).map { line -> String in
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            var rest = String(line.dropFirst(leading.count))
            if rest.hasPrefix("- [ ]") {
                rest = "- ☐" + rest.dropFirst("- [ ]".count)
            } else if rest.hasPrefix("- [x]") || rest.hasPrefix("- [X]") {
                rest = "- ☑" + rest.dropFirst("- [x]".count)
            } else if rest.hasPrefix("- [") {
                // Any other bracket bullet still reads as a transcript line
                // to the search parser — soften just the bullet.
                rest = "- (" + rest.dropFirst("- [".count)
                if let close = rest.firstIndex(of: "]") {
                    rest.replaceSubrange(close...close, with: ")")
                }
            } else if rest.hasPrefix("## ") {
                rest = "#" + rest   // demote: header block stays ours
            }
            return leading + rest
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    /// Dedupe markers already present in the sessions folder — read from
    /// the header block only (first 12 lines) to keep re-import scans fast.
    private static func existingImportMarkers(in dir: URL) -> Set<String> {
        var markers: Set<String> = []
        for file in TranscriptSearch.sessionFiles(in: dir) {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: .newlines).prefix(12) {
                if line.hasPrefix("**Imported-From:**") {
                    markers.insert(line.dropFirst("**Imported-From:**".count)
                        .trimmingCharacters(in: .whitespaces))
                }
                if line.hasPrefix("## ") { break }
            }
        }
        return markers
    }

    private static func nested(_ dict: [String: Any]?, _ keys: String...) -> String? {
        var current: Any? = dict
        for key in keys {
            current = (current as? [String: Any])?[key]
        }
        return current as? String
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func isoDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return isoWithFraction.date(from: string) ?? isoPlain.date(from: string)
    }

    /// First "yyyy-MM-dd" (optionally with a time) found in a line of an
    /// exported file's head.
    private static func dateInLine(_ line: String) -> Date? {
        guard let match = line.range(of: #"\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2})?"#,
                                     options: .regularExpression) else { return nil }
        let found = String(line[match]).replacingOccurrences(of: "T", with: " ")
        let f = DateFormatter()
        if found.count > 10 {
            f.dateFormat = "yyyy-MM-dd HH:mm"
            if let d = f.date(from: found) { return d }
        }
        f.dateFormat = "yyyy-MM-dd"
        // Date-only: land mid-day so the stamp never straddles midnight
        // (and 00-00 files from different days can't collide).
        return f.date(from: String(found.prefix(10)))?.addingTimeInterval(12 * 3600)
    }

    private static func mmss(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
