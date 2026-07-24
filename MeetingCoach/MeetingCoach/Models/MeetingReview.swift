import Foundation

/// One checkable next step from a meeting. Identity is per-run only —
/// persistence is the `- [ ]` task lines in the session file.
struct ActionItem: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isDone: Bool = false
}

/// Structured post-meeting review. Both review paths produce this — the
/// deterministic (no-LLM) builder directly, the LLM path via `parse` — so
/// the UI never renders a raw text blob and internal signal ids never leak.
struct MeetingReview: Equatable {
    var summary: String = ""
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

    var isEmpty: Bool { summary.isEmpty && takeaways.isEmpty && actionItems.isEmpty }

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
    static func parse(llmText: String, talkShare: Double? = nil) -> MeetingReview {
        enum Section { case summary, takeaways, nextSteps, wins, focus }
        var review = MeetingReview(talkShare: talkShare)
        var section = Section.summary
        var summaryLines: [String] = []
        var focusLines: [String] = []

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
            if h.hasPrefix("summary") { return .summary }
            if h.contains("takeaway") || h.contains("key point") || h.contains("highlight") { return .takeaways }
            if h.contains("next step") || h.contains("action item")
                || h.contains("decision ledger") || h.contains("recommendation") { return .nextSteps }
            if h.hasPrefix("win") || h.contains("went well") { return .wins }
            if h.contains("focus") || h.hasPrefix("next meeting") { return .focus }
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

        for rawLine in llmText.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let s = sectionFor(header: line) { section = s; continue }
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
            case .summary:
                summaryLines.append(bullet ?? clean(line))
            case .takeaways:
                appendOrContinue(bullet, line, to: &review.takeaways)
            case .nextSteps:
                if let bullet {
                    review.actionItems.append(ActionItem(text: bullet))
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
