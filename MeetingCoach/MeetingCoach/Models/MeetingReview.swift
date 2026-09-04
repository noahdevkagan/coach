import Foundation

/// One checkable next step from a meeting. Identity is per-run only —
/// persistence is the `- [ ]` task lines in the session file.
struct ActionItem: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isDone: Bool = false
}

/// One topic section of the meeting notes ("### Pricing and margin" plus
/// its bullets) — the Granola-style body that replaced the flat
/// KEY TAKEAWAYS list (Noah, 2026-09-04).
struct ReviewSection: Equatable {
    var heading: String
    var bullets: [String] = []
}

/// Structured post-meeting review. Both review paths produce this — the
/// deterministic (no-LLM) builder directly, the LLM path via `parse` — so
/// the UI never renders a raw text blob and internal signal ids never leak.
struct MeetingReview: Equatable {
    /// LLM-proposed session title ("Caitlin · margins & win-back") — the
    /// model has read the whole meeting, so it names it far better than
    /// the word-frequency heuristic. nil on the deterministic path.
    var title: String?
    var summary: String = ""
    /// Topic-grouped meeting notes (the NOTES: body). Empty on the
    /// deterministic path and for pre-0.22 saved reviews, which carry
    /// the flat `takeaways` list instead.
    var sections: [ReviewSection] = []
    var takeaways: [String] = []
    var actionItems: [ActionItem] = []
    var wins: [String] = []
    var nextFocus: String?
    /// Whole-meeting talk split (0…1 you) — deliberately whole-meeting, in
    /// contrast to the live nudges' recent windows.
    var talkShare: Double?
    /// True for the instant on-device review (no local model) — the UI
    /// shows a footnote instead of pretending it was the AI review.
    var isDeterministic = false

    var isEmpty: Bool {
        summary.isEmpty && sections.isEmpty && takeaways.isEmpty && actionItems.isEmpty
    }

    /// Shareable / persisted rendition. This goes into the session .md file
    /// and the copy/share recap, where markdown is the right format —
    /// the in-app card renders the struct, never this string.
    var recapMarkdown: String {
        var lines: [String] = []
        if !summary.isEmpty {
            lines.append("**Summary**")
            lines.append(summary)
            lines.append("")
        }
        if let share = talkShare {
            lines.append("Talk split (whole meeting): you \(Int(share * 100))% · them \(100 - Int(share * 100))%")
            lines.append("")
        }
        for section in sections {
            lines.append("### \(section.heading)")
            lines.append(contentsOf: section.bullets.map { "- \($0)" })
            lines.append("")
        }
        if !takeaways.isEmpty {
            lines.append("**Key Takeaways**")
            lines.append(contentsOf: takeaways.map { "- \($0)" })
            lines.append("")
        }
        if !wins.isEmpty {
            lines.append("**Wins**")
            lines.append(contentsOf: wins.map { "- \($0)" })
            lines.append("")
        }
        if !actionItems.isEmpty {
            lines.append("**Suggested Next Steps**")
            lines.append(contentsOf: actionItems.map { "- [\($0.isDone ? "x" : " ")] \($0.text)" })
            lines.append("")
        }
        if let focus = nextFocus, !focus.isEmpty {
            lines.append("**Next meeting:** \(focus)")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - LLM output parsing

    /// Tolerant parse of the local model's review. Recognizes the labeled
    /// sections PromptBuilder asks for, but survives markdown decoration,
    /// numbering, and tables — and when nothing parses, the whole cleaned
    /// text lands in `summary` so content is never dropped on the floor.
    /// Title hygiene: models wrap names in quotes or run long — strip
    /// decoration, collapse whitespace, hard-cap for the sidebar.
    private static func clipTitle(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’.*_"))
        t = t.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !t.isEmpty else { return nil }
        if t.count > 60 { t = String(t.prefix(57)) + "…" }
        return t
    }

    static func parse(llmText: String, talkShare: Double? = nil) -> MeetingReview {
        enum Section { case title, summary, notes, takeaways, nextSteps, wins, focus }
        var review = MeetingReview(talkShare: talkShare)
        var section = Section.summary
        var summaryLines: [String] = []
        var focusLines: [String] = []
        /// True once a "### topic" line opened a section — content then
        /// routes to `sections.last` until the next known header.
        var inTopic = false

        func sectionFor(header line: String) -> Section? {
            var h = line.trimmingCharacters(in: .whitespaces).lowercased()
            // A bullet is content, never a header ("- wins matter here"
            // must not flip the section).
            for marker in ["- ", "* ", "• "] where h.hasPrefix(marker) { return nil }
            h = h.trimmingCharacters(in: CharacterSet(charactersIn: "#*_ \t"))
            // Strip leading numbering: "1. key takeaways" → "key takeaways"
            while let first = h.first, first.isNumber || first == "." || first == ")" || first == " " {
                h.removeFirst()
            }
            h = h.trimmingCharacters(in: CharacterSet(charactersIn: ": *_"))
            guard !h.isEmpty, h.count <= 40 else { return nil }
            if h == "title" || h == "meeting title" || h == "session title" { return .title }
            if h.hasPrefix("summary") { return .summary }
            if h == "notes" || h == "meeting notes" || h == "discussion notes" { return .notes }
            if h.contains("takeaway") || h.contains("key point") || h.contains("highlight")
                || h.contains("discussion point") || h.contains("key discussion")
                || h.contains("quick update") { return .takeaways }
            if h.contains("next step") || h.contains("action item")
                || h.contains("decision ledger") || h.contains("recommendation") { return .nextSteps }
            if h.hasPrefix("win") || h.contains("went well") { return .wins }
            if h.contains("focus") || h.hasPrefix("next meeting") { return .focus }
            return nil
        }

        // "SUMMARY: The call covered…" — label and content on one line.
        // sectionFor only recognizes bare headers (it rejects long lines),
        // so models that glue the first sentence onto the label used to
        // leak "SUMMARY:" into the text and dump "NEXT MEETING FOCUS: …"
        // into the previous section as a continuation line.
        func inlineHeader(_ line: String) -> (Section, String)? {
            let stripped = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*_ \t"))
            let lower = stripped.lowercased()
            let labels: [(String, Section)] = [
                ("title", .title),
                ("summary", .summary),
                ("notes", .notes),
                ("meeting notes", .notes),
                ("key takeaways", .takeaways),
                ("takeaways", .takeaways),
                ("key points", .takeaways),
                ("key discussion points", .takeaways),
                ("discussion points", .takeaways),
                ("suggested next steps", .nextSteps),
                ("next steps", .nextSteps),
                ("action items", .nextSteps),
                ("next meeting focus", .focus),
                // After "next meeting focus" on purpose (first prefix hit
                // wins) — this one round-trips recapMarkdown's own
                // "**Next meeting:** …" line back into `nextFocus`.
                ("next meeting", .focus),
                ("wins", .wins),
            ]
            for (label, sec) in labels where lower.hasPrefix(label) {
                var rest = String(stripped.dropFirst(label.count))
                    .trimmingCharacters(in: .whitespaces)
                guard rest.hasPrefix(":") else { continue }
                rest.removeFirst()
                return (sec, clean(rest))
            }
            return nil
        }

        func bulletText(_ line: String) -> String? {
            var t = line.trimmingCharacters(in: .whitespaces)
            var isBullet = false
            for prefix in ["- [x]", "- [X]", "- [ ]", "-", "*", "•", "·"] where t.hasPrefix(prefix) {
                t = String(t.dropFirst(prefix.count))
                isBullet = true
                break
            }
            if !isBullet {
                // "1. thing" / "2) thing"
                let digits = t.prefix(while: \.isNumber)
                if (1...2).contains(digits.count) {
                    let rest = t.dropFirst(digits.count)
                    if rest.hasPrefix(".") || rest.hasPrefix(")") {
                        t = String(rest.dropFirst())
                        isBullet = true
                    }
                }
            }
            guard isBullet else { return nil }
            let cleaned = clean(t)
            return cleaned.isEmpty ? nil : cleaned
        }

        // Drop any preamble before the first recognized header — small
        // models love a meta paragraph ("Note on coaching signals: …")
        // before SUMMARY, which used to pollute the summary text. If no
        // header exists anywhere, keep everything (fallback path below).
        let allLines = llmText.components(separatedBy: .newlines)
        var startIndex = 0
        for (i, raw) in allLines.enumerated() {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if inlineHeader(t) != nil || sectionFor(header: t) != nil {
                startIndex = i
                break
            }
        }

        for rawLine in allLines[startIndex...] {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // recapMarkdown's own talk-split line — carried by `talkShare`,
            // never by text (re-parsing used to glue it onto the summary).
            if line.hasPrefix("Talk split (") { continue }
            if let (s, rest) = inlineHeader(line) {
                section = s
                inTopic = false
                if !rest.isEmpty {
                    switch s {
                    case .title: if review.title == nil { review.title = clipTitle(rest) }
                    case .summary: summaryLines.append(rest)
                    case .notes, .takeaways: review.takeaways.append(rest)
                    case .nextSteps: review.actionItems.append(ActionItem(text: rest))
                    case .wins: review.wins.append(rest)
                    case .focus: focusLines.append(rest)
                    }
                }
                continue
            }
            // "### Pricing and margin" — a topic heading inside the NOTES
            // body (any # depth; recapMarkdown always writes "### ").
            // Checked BEFORE sectionFor: its fuzzy matching would hijack a
            // topic that merely contains a section word ("Role and focus"
            // is a topic, not the NEXT MEETING FOCUS header) — only the
            // canonical section names may switch sections from a # line.
            // Bold-wrapped headings ("**Pricing**") count too, but only
            // inside notes — elsewhere a bold line is emphasized content.
            let isTopicLine = line.hasPrefix("#")
                || (section == .notes && line.hasPrefix("**") && line.hasSuffix("**")
                    && line.count > 4)
            if isTopicLine {
                let heading = clean(line).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                let canonical: Set<String> = [
                    "title", "summary", "notes", "meeting notes",
                    "key takeaways", "takeaways", "wins",
                    "next steps", "suggested next steps", "action items",
                    "next meeting focus", "next meeting",
                ]
                if !heading.isEmpty, heading.count <= 60,
                   !canonical.contains(heading.lowercased()) {
                    review.sections.append(ReviewSection(heading: heading))
                    section = .notes
                    inTopic = true
                    continue
                }
            }
            if let s = sectionFor(header: line) { section = s; inTopic = false; continue }
            // Table rows ("| decision | owner |") → joined cells; separator
            // rows ("|---|---|") are skipped.
            if line.hasPrefix("|") {
                let cells = line.split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { cell in
                        !cell.isEmpty && !cell.allSatisfy { "-: ".contains($0) }
                    }
                guard !cells.isEmpty else { continue }
                line = "- " + cells.joined(separator: " — ")
            }
            let bullet = bulletText(line)
            switch section {
            case .title:
                // First content line only — anything further is a model
                // rambling past the label, not part of the name.
                if review.title == nil { review.title = clipTitle(bullet ?? clean(line)) }
            case .summary:
                summaryLines.append(bullet ?? clean(line))
            case .notes:
                // Bullets under an opened "### topic" belong to it; notes
                // content before any topic degrades to the flat takeaways
                // list so nothing is dropped.
                if inTopic, !review.sections.isEmpty {
                    appendOrContinue(bullet, line,
                                     to: &review.sections[review.sections.count - 1].bullets)
                } else {
                    appendOrContinue(bullet, line, to: &review.takeaways)
                }
            case .takeaways:
                appendOrContinue(bullet, line, to: &review.takeaways)
            case .nextSteps:
                if let bullet {
                    // "- [x]" task lines round-trip their checked state
                    // (the session file is the persistence for checkboxes).
                    let done = line.trimmingCharacters(in: .whitespaces)
                        .lowercased().hasPrefix("- [x]")
                    review.actionItems.append(ActionItem(text: bullet, isDone: done))
                } else if !review.actionItems.isEmpty {
                    review.actionItems[review.actionItems.count - 1].text += " " + clean(line)
                } else {
                    review.actionItems.append(ActionItem(text: clean(line)))
                }
            case .wins:
                appendOrContinue(bullet, line, to: &review.wins)
            case .focus:
                focusLines.append(bullet ?? clean(line))
            }
        }

        review.summary = summaryLines.joined(separator: " ")
        if !focusLines.isEmpty { review.nextFocus = focusLines.joined(separator: " ") }
        if review.actionItems.count > 8 { review.actionItems.removeLast(review.actionItems.count - 8) }
        review.sections.removeAll { $0.bullets.isEmpty }
        if review.sections.count > 8 { review.sections.removeLast(review.sections.count - 8) }

        if review.isEmpty {
            // Unparseable response — degrade to readable text, never blank.
            review.summary = llmText.components(separatedBy: .newlines)
                .map(clean).filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        return review
    }

    /// A prose line continues the previous bullet; a bullet starts a new item.
    private static func appendOrContinue(_ bullet: String?, _ line: String,
                                         to items: inout [String]) {
        if let bullet {
            items.append(bullet)
        } else if !items.isEmpty {
            items[items.count - 1] += " " + clean(line)
        } else {
            items.append(clean(line))
        }
    }

    /// Strip the markdown decoration small local models sprinkle in even
    /// when told not to — the UI must never show literal `**` or `#`.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        while t.hasPrefix("#") { t.removeFirst() }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
