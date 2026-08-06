import Foundation

/// Import of Granola meeting history into MeetingCoach sessions, from the
/// CSV export Granola produces once the user enables data export. The
/// earlier direct read of Granola's local cache is gone on purpose: newer
/// Granola versions encrypt that cache, so the one supported path is the
/// format Granola itself commits to — export, then pick the file here.
///
/// Imported sessions are ordinary `session_yyyy-MM-dd_HH-mm.md` files in
/// the transcripts folder, stamped with the meeting's ORIGINAL date (the
/// filename is the only date the dashboard/search parsers read), and carry
/// an `**Imported-From:**` header line as the re-import dedupe marker.
enum GranolaImporter {
    struct Report: Sendable {
        var imported = 0
        var updated = 0
        var skippedExisting = 0
        var skippedNoDate = 0

        var summary: String {
            var parts = ["Imported \(imported) meeting\(imported == 1 ? "" : "s")"]
            if updated > 0 { parts.append("\(updated) updated with transcript") }
            if skippedExisting > 0 { parts.append("\(skippedExisting) already imported") }
            if skippedNoDate > 0 { parts.append("\(skippedNoDate) skipped (no date)") }
            return parts.joined(separator: " · ")
        }
    }

    enum ImportError: LocalizedError {
        case unreadableFile
        case notAGranolaCSV

        var errorDescription: String? {
            switch self {
            case .unreadableFile:
                return "Couldn't read that file."
            case .notAGranolaCSV:
                return "That doesn't look like a Granola CSV export — it needs a header row with a date column plus a title or notes column."
            }
        }
    }

    // MARK: - CSV import

    static func importCSV(_ url: URL, into dir: URL = AppSupport.sessionsDir) throws -> Report {
        guard var text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ImportError.unreadableFile
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }  // UTF-8 BOM

        let rows = parseCSV(text)
        guard rows.count > 1, let header = rows.first else { throw ImportError.notAGranolaCSV }

        // Column lookup is by name, not position — Granola owns the export
        // format and may reorder or add columns. Exact match wins over
        // substring so "notes" can't accidentally bind to "notes_url".
        let cols = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func col(_ names: [String]) -> Int? {
            for name in names {
                if let i = cols.firstIndex(of: name) { return i }
            }
            for name in names {
                if let i = cols.firstIndex(where: { $0.contains(name) }) { return i }
            }
            return nil
        }
        // Verified against a real export (2026-08-04): document_id,
        // user_email, document_title, workspace_name, document_created,
        // summary, notes, transcript. `notes` is the user's typed notes and
        // is usually EMPTY — Granola's auto-notes live in `summary`, and
        // the full transcript in `transcript`. The first importer bound
        // "notes" alone and produced title-only shells.
        let idCol = col(["id", "document_id"])
        let dateCol = col(["date", "created_at", "created", "start", "time"])
        let titleCol = col(["title", "name", "meeting"])
        let notesCol = col(["notes", "content", "body"])
        let summaryCol = col(["summary"])
        let transcriptCol = col(["transcript"])
        let attendeesCol = col(["attendees", "participants", "people"])
        let endCol = col(["end"])
        guard dateCol != nil, titleCol != nil || notesCol != nil || summaryCol != nil else {
            throw ImportError.notAGranolaCSV
        }

        let existing = existingImportMarkers(in: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var report = Report()
        for row in rows.dropFirst() {
            func field(_ index: Int?) -> String {
                guard let index, index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let title = field(titleCol)
            // User-typed notes first, Granola's generated summary after —
            // both survive, either alone is fine.
            var notes = [field(notesCol), field(summaryCol)]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            let attendees = field(attendeesCol)
            if !attendees.isEmpty {
                notes = "Attendees: \(attendees)\n\n\(notes)"
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let transcript = transcriptLines(field(transcriptCol))
            // Nothing to bring over — not worth a file (or a report line).
            guard !title.isEmpty || !notes.isEmpty || !transcript.isEmpty else { continue }

            guard let date = parseDate(field(dateCol)) else {
                // A wrong date in a date-keyed archive is worse than absence.
                report.skippedNoDate += 1
                continue
            }
            let duration = parseDate(field(endCol)).map { $0.timeIntervalSince(date) }

            // Same "granola:<id>" marker the retired cache importer wrote,
            // so meetings imported before the CSV switch don't duplicate.
            let id = field(idCol)
            let marker = id.isEmpty
                ? "granola-csv:\(title)@\(isoPlain.string(from: date))"
                : "granola:\(id)"
            if let existingFile = existing[marker] {
                // The pre-0.12.0 importer wrote title-only shells (the CSV
                // parse dropped every column past the header); the marker
                // then blocked re-imports from ever fixing them. A shell
                // with no transcript + a CSV row that has one = heal in
                // place. Only the transcript section is appended — the
                // user's file (title renames, notes) is otherwise theirs.
                if !transcript.isEmpty, backfillTranscript(transcript, into: existingFile) {
                    report.updated += 1
                } else {
                    report.skippedExisting += 1
                }
                continue
            }

            write(marker: marker, title: title, date: date,
                  duration: duration, notes: notes, transcript: transcript, into: dir)
            report.imported += 1
        }
        return report
    }

    /// RFC 4180 CSV: quoted fields may hold commas, newlines, and doubled
    /// quotes. Granola notes are multi-line, so a line-based split won't do.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() { row.append(field); field = "" }
        func endRow() {
            endField()
            // Skip blank lines (common as a trailing newline).
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let c = pending ?? iterator.next() {
            pending = nil
            switch c {
            case "\"" where inQuotes:
                if let next = iterator.next() {
                    if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                } else {
                    inQuotes = false
                }
            case "\"" where field.isEmpty:
                inQuotes = true
            case "," where !inQuotes:
                endField()
            case "\r\n" where !inQuotes:
                // CRLF is ONE Character in Swift (grapheme cluster) — it
                // matches neither "\r" nor "\n" below, so without this case
                // a CRLF-terminated header glues the whole file into one
                // row. Granola's real export mixes exactly one CRLF (after
                // the header) with LF everywhere else; this was the
                // "import does nothing" bug (2026-08-04).
                endRow()
            case "\r" where !inQuotes:
                break  // bare CR: normalize to the LF handling below
            case "\n" where !inQuotes:
                endRow()
            default:
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    // MARK: - Session file writing

    /// Granola transcript cells are "Speaker A: text" lines with no
    /// timestamps. Convert to the session line shape the app's parsers read
    /// ("- [--:--] Speaker: text" — the placeholder stamp is honest about
    /// having no times and parses fine); soft-wrapped continuations fold
    /// into the turn above.
    static func transcriptLines(_ cell: String) -> [String] {
        var out: [String] = []
        for raw in cell.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let colon = line.firstIndex(of: ":"), colon != line.startIndex {
                let speaker = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let text = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                // Speaker labels are short name-ish runs ("Speaker A",
                // "Noah Kagan") — a colon deep into a sentence isn't one.
                if !text.isEmpty, speaker.count <= 40,
                   speaker.split(separator: " ").count <= 4,
                   !speaker.contains(where: { ".,!?".contains($0) }) {
                    out.append("- [--:--] \(speaker): \(text)")
                    continue
                }
            }
            if out.isEmpty {
                out.append("- [--:--] Speaker: \(line)")
            } else {
                out[out.count - 1] += " " + line
            }
        }
        return out
    }

    private static func write(marker: String, title: String, date: Date,
                              duration: TimeInterval?, notes: String,
                              transcript: [String], into dir: URL) {
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
        lines.append("**Utterances:** \(transcript.count)")
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

        if !transcript.isEmpty {
            lines.append("## Transcript")
            lines.append(contentsOf: transcript)
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

    /// Dedupe markers already present in the sessions folder (marker → its
    /// session file, so re-imports can heal transcript-less shells) — read
    /// from the header block only (first 12 lines) to keep scans fast.
    private static func existingImportMarkers(in dir: URL) -> [String: URL] {
        var markers: [String: URL] = [:]
        for file in TranscriptSearch.sessionFiles(in: dir) {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: .newlines).prefix(12) {
                if line.hasPrefix("**Imported-From:**") {
                    let marker = line.dropFirst("**Imported-From:**".count)
                        .trimmingCharacters(in: .whitespaces)
                    markers[marker] = file
                }
                if line.hasPrefix("## ") { break }
            }
        }
        return markers
    }

    /// Append a transcript to an already-imported session that has none
    /// (a shell from the broken pre-0.12.0 importer), updating the
    /// utterance count in the header. Returns false when the file already
    /// has a transcript (nothing to heal) or can't be read.
    static func backfillTranscript(_ transcript: [String], into file: URL) -> Bool {
        guard let content = try? String(contentsOf: file, encoding: .utf8),
              !content.contains("\n## Transcript") else { return false }
        var lines = content.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix("**Utterances:**") }) {
            lines[i] = "**Utterances:** \(transcript.count)"
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        lines.append("")
        lines.append("## Transcript")
        lines.append(contentsOf: transcript)
        lines.append("")
        return (try? lines.joined(separator: "\n")
            .write(to: file, atomically: true, encoding: .utf8)) != nil
    }

    nonisolated(unsafe) private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

    /// Dates in an export vary with the tool that wrote them — try ISO 8601
    /// first, then the "yyyy-MM-dd[ HH:mm]" shapes spreadsheets produce.
    private static func parseDate(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        return isoWithFraction.date(from: string)
            ?? isoPlain.date(from: string)
            ?? dateInLine(string)
    }

    /// First "yyyy-MM-dd" (optionally with a time) found in the text.
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
}
