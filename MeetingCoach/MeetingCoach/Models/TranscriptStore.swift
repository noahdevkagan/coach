import Foundation

/// Naming, sidecar metadata, and the append-only index for saved
/// transcripts — everything an external AI tool (Claude, ChatGPT, Cursor)
/// needs to use the folder with zero MeetingCoach-specific integration.
///
/// New transcripts are named `2026-08-31T14-30_partner-sync_chad-anna.md`
/// (ISO date-time, slugified title, slugified participants) so a plain
/// directory listing sorts chronologically and globs like `*partner-sync*`
/// find the right meeting. Each transcript gets a `<same-stem>.json`
/// sidecar, and one line per meeting is appended to `index.jsonl` in the
/// transcripts folder. Foundation-only on purpose — test rigs compile this
/// file standalone next to AppSupport/TranscriptSearch.
enum TranscriptStore {
    // MARK: - Filenames

    /// Filesystem-safe slug: lowercased ASCII letters/digits joined by
    /// single hyphens, diacritics folded ("Café Sync" → "cafe-sync").
    /// Returns "" when nothing survives (emoji-only, CJK…) — callers omit
    /// the segment rather than invent one.
    static func slug(_ text: String, maxLength: Int = 40) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                  locale: Locale(identifier: "en_US"))
        var out = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(Character(scalar))
                if out.count >= maxLength { break }
            } else {
                pendingDash = true
            }
        }
        return out
    }

    /// "2026-08-31T14-30_partner-sync_chad-anna" — date-time first so names
    /// sort chronologically; title and participants only when known.
    /// Participants contribute first names ("Chad Smith" → "chad") so the
    /// name stays scannable in a Finder column.
    static func filenameStem(date: Date, title: String?, participants: [String]) -> String {
        var parts = [stampFormatter.string(from: date)]
        if let titleSlug = title.map({ slug($0) }), !titleSlug.isEmpty {
            parts.append(titleSlug)
        }
        let people = participants
            .compactMap { name -> String? in
                let first = name.split(separator: " ").first.map(String.init) ?? name
                let s = slug(first, maxLength: 20)
                return s.isEmpty ? nil : s
            }
        if !people.isEmpty {
            parts.append(people.prefix(4).joined(separator: "-"))
        }
        return parts.joined(separator: "_")
    }

    /// The transcript file to write, dodging collisions with a numeric
    /// suffix ("…_chad-anna-2.md") — the date prefix, the only part parsers
    /// read, is untouched.
    static func uniqueTranscriptFile(in dir: URL, date: Date,
                                     title: String?, participants: [String]) -> URL {
        let stem = filenameStem(date: date, title: title, participants: participants)
        var file = dir.appendingPathComponent("\(stem).md")
        var n = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = dir.appendingPathComponent("\(stem)-\(n).md")
            n += 1
        }
        return file
    }

    nonisolated(unsafe) private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm"
        return f
    }()

    // MARK: - Machine-readable metadata

    struct Metadata {
        var title: String?
        var startedAt: Date
        var durationMin: Double
        var participants: [String]
        /// "meetingcoach" for live-coached sessions, "granola-import" for
        /// meetings brought over from a Granola export.
        var source: String
    }

    /// Write the `<transcript-stem>.json` sidecar and append the same
    /// record (plus the transcript-root-relative path) to `index.jsonl`.
    /// The index is append-only — one line per meeting, never rewritten —
    /// so external tools can tail it or parse it as JSONL.
    static func record(_ meta: Metadata, for transcript: URL) {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        var dict: [String: Any] = [
            "started_at": iso.string(from: meta.startedAt),
            "duration_min": (meta.durationMin * 10).rounded() / 10,
            "participants": meta.participants,
            "source": meta.source,
            "transcript": transcript.lastPathComponent,
        ]
        if let title = meta.title, !title.isEmpty { dict["title"] = title }

        let sidecar = transcript.deletingPathExtension().appendingPathExtension("json")
        if let data = try? JSONSerialization.data(withJSONObject: dict,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: sidecar)
        }

        // Transcripts live flat in the folder, so the relative path is the
        // filename — kept as a separate field per the index contract.
        dict["path"] = transcript.lastPathComponent
        guard let line = try? JSONSerialization.data(withJSONObject: dict,
                                                     options: [.sortedKeys]) else { return }
        let index = transcript.deletingLastPathComponent()
            .appendingPathComponent("index.jsonl")
        if !FileManager.default.fileExists(atPath: index.path) {
            FileManager.default.createFile(atPath: index.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: index) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line + Data("\n".utf8))
    }

    /// Best-effort metadata for an already-saved session file: date from
    /// the filename, the rest from the header block the app writes. Nil
    /// only when the filename has no date (not a session file).
    static func metadataByParsing(_ file: URL) -> Metadata? {
        guard let date = TranscriptSearch.sessionDate(for: file) else { return nil }
        let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var durationMin = 0.0
        var participants: [String] = []
        var source = "meetingcoach"
        for line in content.components(separatedBy: "\n").prefix(24) {
            if line.hasPrefix("**Duration:**") {
                let parts = line.dropFirst("**Duration:**".count)
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: ":").compactMap { Double($0) }
                if parts.count == 2 { durationMin = parts[0] + parts[1] / 60 }
            } else if line.hasPrefix("**Participants:**") {
                // Header shape is "Name (role), Name (role)" — keep the names.
                participants = line.dropFirst("**Participants:**".count)
                    .split(separator: ",")
                    .map {
                        $0.trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: #"\s*\(.*\)$"#, with: "",
                                                  options: .regularExpression)
                    }
                    .filter { !$0.isEmpty }
            } else if line.hasPrefix("**Imported-From:**") {
                source = "granola-import"
            }
        }
        return Metadata(title: TranscriptSearch.headerTitle(in: content),
                        startedAt: date, durationMin: durationMin,
                        participants: participants, source: source)
    }

    // MARK: - One-time migration into the transcripts subfolder

    /// Pre-0.21 default: session files sat directly in ~/Documents/MeetingCoach.
    /// The launch after updating, COPY (never move — the originals are the
    /// user's data and other tools may already point at them) every
    /// session-shaped file into the transcripts/ subfolder and index the
    /// copies so external tools see a complete catalog. Users who picked a
    /// custom folder in Settings keep it untouched. Returns the number of
    /// files copied.
    @discardableResult
    static func migrateLegacyDefaultIfNeeded() -> Int {
        let defaults = UserDefaults.standard
        let migratedKey = "didMigrateTranscriptsSubfolder"
        guard !defaults.bool(forKey: migratedKey) else { return 0 }
        defer { defaults.set(true, forKey: migratedKey) }
        // A custom folder is the user's explicit choice of location.
        if let custom = defaults.string(forKey: AppSupport.sessionFolderKey),
           !custom.isEmpty { return 0 }

        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(
            at: AppSupport.legacyDefaultSessionsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { TranscriptSearch.isSessionFilename($0.lastPathComponent) }
        guard !files.isEmpty else { return 0 }

        let dest = AppSupport.sessionsDir
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var copied = 0
        for file in files {
            // The copy keeps its name, so a file already sitting there is
            // this same session: a second run must be a no-op. The one-shot
            // flag alone doesn't guarantee that — a second Mac with the same
            // iCloud-synced Documents (or a Documents-only restore) starts
            // with the flag unset and both folders populated, and suffixed
            // copies would double every meeting in the list and the index.
            let target = dest.appendingPathComponent(file.lastPathComponent)
            guard !fm.fileExists(atPath: target.path) else { continue }
            guard (try? fm.copyItem(at: file, to: target)) != nil else { continue }
            copied += 1
            if let meta = metadataByParsing(target) { record(meta, for: target) }
        }
        return copied
    }
}
