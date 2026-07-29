import SwiftUI
import AppKit

/// Read-only viewer for a saved session, shown in the main pane — clicking
/// a session opens here (readable, copyable) instead of bouncing to a text
/// editor. The markdown file on disk stays the source of truth; the
/// external editor is still one click away for anyone who wants the file.
struct SessionDetailView: View {
    let url: URL
    let onClose: () -> Void

    @State private var title = ""
    @State private var stats: [String] = []
    @State private var review: MeetingReview?
    @State private var lines: [(stamp: String, speaker: String, text: String)] = []
    @State private var rawContent = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(MCTheme.paneTitle)
                    .lineLimit(1)
                Text(TranscriptSearch.title(for: url))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if !stats.isEmpty {
                    Text(stats.joined(separator: " · "))
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                CopyButton(help: "Copy the whole session — paste into Slack, email, or an AI tool") {
                    rawContent
                }
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open the file in your editor")
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Close")
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
            Divider().opacity(0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    // Same structured card the post-call review uses — old
                    // free-text reviews go through the same tolerant parser,
                    // so no saved session ever renders raw markdown.
                    if let review {
                        MeetingReviewView(review: review) { id in
                            toggleActionItem(id)
                        }
                    }

                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(line.stamp)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(line.speaker)
                                .font(.caption2.bold())
                                .foregroundStyle(line.speaker == "You" ? .blue : .purple)
                            Text(line.text)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if lines.isEmpty {
                        Text("No transcript lines in this session.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MCTheme.canvas)
        .task(id: url) { load() }
    }

    private func load() {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            title = "Couldn't read session"
            stats = []; review = nil; lines = []; rawContent = ""
            return
        }
        rawContent = content
        title = TranscriptSearch.headerTitle(in: content) ?? TranscriptSearch.title(for: url)

        var newStats: [String] = []
        var newLines: [(String, String, String)] = []
        var reviewLines: [String] = []
        var inReview = false
        for rawLine in content.components(separatedBy: "\n") {
            if rawLine.hasPrefix("## ") {
                inReview = rawLine.hasPrefix("## Review")
                continue
            }
            if inReview {
                reviewLines.append(rawLine)
                continue
            }
            if let parsed = TranscriptSearch.parseTranscriptLine(rawLine) {
                newLines.append(parsed)
                continue
            }
            for key in ["**Duration:**", "**Talk ratio:**", "**Nudges:**"]
            where rawLine.hasPrefix(key) {
                let label = key.replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: ":", with: "")
                let value = rawLine.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                newStats.append("\(value) \(label.lowercased() == "duration" ? "" : label.lowercased())"
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        stats = newStats
        lines = newLines

        // "**Talk ratio:** 53% you" → 0.53, for the card's talk-split line.
        var talkShare: Double?
        for rawLine in content.components(separatedBy: "\n").prefix(16)
        where rawLine.hasPrefix("**Talk ratio:**") {
            let digits = rawLine.dropFirst("**Talk ratio:**".count)
                .trimmingCharacters(in: .whitespaces)
                .prefix(while: \.isNumber)
            if let pct = Int(digits) { talkShare = Double(pct) / 100 }
        }

        let reviewText = reviewLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        review = reviewText.isEmpty
            ? nil
            : MeetingReview.parse(llmText: reviewText, talkShare: talkShare)
    }

    /// Checkbox toggles persist straight into the file's "## Review"
    /// section — same behavior as the post-call card.
    private func toggleActionItem(_ id: UUID) {
        guard var updated = review,
              let i = updated.actionItems.firstIndex(where: { $0.id == id }) else { return }
        updated.actionItems[i].isDone.toggle()
        review = updated
        guard var content = try? String(contentsOf: url, encoding: .utf8) else { return }
        if let range = content.range(of: "\n## Review") {
            content = String(content[..<range.lowerBound])
        }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        content += "\n\n## Review\n\n\(updated.recapMarkdown)\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
        rawContent = content
    }
}
