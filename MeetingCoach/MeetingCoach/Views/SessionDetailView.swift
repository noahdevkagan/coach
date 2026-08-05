import SwiftUI
import AppKit

/// Saved-session viewer in the main pane. Dorado paint on the 0.12.0
/// flow (Noah, 2026-08-04): one scroll — review card first, transcript
/// under it — no tabs. The header adds meta, click-to-rename, Copy and
/// Export; the markdown file on disk stays the source of truth.
struct SessionDetailView: View {
    let url: URL
    /// Active search query — matched terms highlight in the transcript and
    /// the view scrolls to the first hit.
    var highlightQuery: String = ""
    let onClose: () -> Void

    @State private var title = ""
    @State private var metaLine = ""
    @State private var review: MeetingReview?
    @State private var lines: [(stamp: String, speaker: String, text: String)] = []
    @State private var rawContent = ""
    @State private var renaming = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Dorado.divider.frame(height: 1)
                .padding(.top, 18)
            contentScroll
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .task(id: url) { load() }
    }

    // MARK: header — meta, title, actions

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(metaLine)
                    .font(Dorado.roboto(13))
                    .foregroundStyle(Dorado.grey500)
                if renaming {
                    TextField("Session title", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(Dorado.barlowXBold(28))
                        .foregroundStyle(Dorado.midnight)
                        .focused($renameFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { renaming = false }
                } else {
                    Text(title)
                        .font(Dorado.barlowXBold(28))
                        .foregroundStyle(Dorado.midnight)
                        .lineLimit(2)
                        .onTapGesture {
                            renameText = TranscriptSearch.headerTitle(at: url) ?? ""
                            renaming = true
                            renameFocused = true
                        }
                        .help("Click to rename")
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button {
                    copyTranscript()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12)).foregroundStyle(Dorado.grey500)
                        Text("Copy")
                    }
                }
                .buttonStyle(DoradoOutlineButtonStyle())
                .help("Copy the plain-text transcript")

                Menu {
                    Button("Markdown (.md)") { export(as: .markdown) }
                    Button("Plain text (.txt)") { export(as: .plainText) }
                    Button("Summary (.txt)") { export(as: .summary) }
                        .disabled(review == nil)
                    Divider()
                    Button("Open file in editor") { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12)).foregroundStyle(Dorado.grey500)
                        Text("Export")
                    }
                }
                .menuStyle(.button)
                .buttonStyle(DoradoOutlineButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()

                Button { onClose() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "house")
                            .font(.system(size: 12)).foregroundStyle(Dorado.grey500)
                        Text("Home")
                    }
                }
                .buttonStyle(DoradoOutlineButtonStyle())
                .help("Back to your progress")
            }
        }
        .padding(.init(top: 24, leading: 36, bottom: 0, trailing: 36))
    }

    // MARK: body — review card, then transcript (the 0.12.0 order)

    private var contentScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let review {
                        MeetingReviewView(review: review) { id in
                            toggleActionItem(id)
                        }
                    }

                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        HStack(alignment: .top, spacing: 16) {
                            Text(line.stamp)
                                .font(Dorado.mono(12))
                                .foregroundStyle(Dorado.grey400)
                                .frame(width: 52, alignment: .leading)
                                .padding(.top, 3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(line.speaker)
                                    .font(Dorado.barlowBold(14))
                                    .foregroundStyle(line.speaker == "You" ? Dorado.bolt : Dorado.midnight)
                                highlightedText(line.text)
                                    .font(Dorado.roboto(15))
                                    .foregroundStyle(Dorado.grey800)
                                    .lineSpacing(6)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: 640, alignment: .leading)
                            }
                        }
                        .id(i)
                    }
                    if lines.isEmpty {
                        Text("No transcript lines in this session.")
                            .font(Dorado.roboto(13)).foregroundStyle(Dorado.grey400)
                    }
                    Color.clear.frame(height: 40)
                }
                .padding(.init(top: 20, leading: 36, bottom: 0, trailing: 36))
            }
            .onAppear { scrollToFirstHit(proxy) }
            .onChange(of: highlightQuery) { _, _ in scrollToFirstHit(proxy) }
        }
    }

    // MARK: helpers

    private func highlightedText(_ text: String) -> Text {
        guard !highlightQuery.isEmpty else { return Text(text) }
        var attributed = AttributedString(text)
        var searchStart = attributed.startIndex
        while let range = attributed[searchStart...].range(
            of: highlightQuery, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[range].backgroundColor = Dorado.dorado100
            attributed[range].foregroundColor = Dorado.midnight
            searchStart = range.upperBound
        }
        return Text(attributed)
    }

    private func scrollToFirstHit(_ proxy: ScrollViewProxy) {
        guard !highlightQuery.isEmpty,
              let i = lines.firstIndex(where: {
                  $0.text.range(of: highlightQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil
              }) else { return }
        withAnimation { proxy.scrollTo(i, anchor: .center) }
    }

    private func commitRename() {
        renaming = false
        TranscriptSearch.setTitle(renameText, for: url)
        title = TranscriptSearch.displayTitle(for: url)
    }

    private var plainTranscript: String {
        lines.map { "[\($0.stamp)] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plainTranscript, forType: .string)
    }

    private enum ExportKind { case markdown, plainText, summary }

    private func export(as kind: ExportKind) {
        let panel = NSSavePanel()
        let base = title.isEmpty ? url.deletingPathExtension().lastPathComponent : title
        let content: String
        switch kind {
        case .markdown:
            panel.nameFieldStringValue = "\(base).md"
            content = rawContent
        case .plainText:
            panel.nameFieldStringValue = "\(base).txt"
            content = plainTranscript
        case .summary:
            panel.nameFieldStringValue = "\(base) — summary.txt"
            content = review?.recapMarkdown ?? ""
        }
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? content.write(to: dest, atomically: true, encoding: .utf8)
    }

    // MARK: load

    private func load() {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            title = "Couldn't read session"
            metaLine = ""; review = nil; lines = []; rawContent = ""
            return
        }
        rawContent = content
        title = TranscriptSearch.headerTitle(in: content) ?? TranscriptSearch.title(for: url)

        var duration = ""
        var talkShare = ""
        var participants = 0
        var newLines: [(String, String, String)] = []
        var reviewLines: [String] = []
        var section = ""
        for rawLine in content.components(separatedBy: "\n") {
            if rawLine.hasPrefix("## ") {
                section = rawLine
                continue
            }
            if section.hasPrefix("## Review") {
                reviewLines.append(rawLine)
                continue
            }
            if section.hasPrefix("## Nudges") { continue }
            if let parsed = TranscriptSearch.parseTranscriptLine(rawLine) {
                newLines.append(parsed)
                continue
            }
            if rawLine.hasPrefix("**Duration:**") {
                duration = rawLine.dropFirst("**Duration:**".count).trimmingCharacters(in: .whitespaces)
            }
            if rawLine.hasPrefix("**Talk ratio:**") {
                talkShare = rawLine.dropFirst("**Talk ratio:**".count).trimmingCharacters(in: .whitespaces)
            }
            if rawLine.hasPrefix("**Participants:**") {
                participants = rawLine.split(separator: ",").count
            }
        }
        lines = newLines

        // "Today, 9:00 AM · 32 min · 4 people · 41% your talk share"
        var meta: [String] = []
        if let date = Dorado.sessionDate(url) {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            let day = Calendar.current.isDateInToday(date) ? "Today"
                : Calendar.current.isDateInYesterday(date) ? "Yesterday"
                : { let d = DateFormatter(); d.dateFormat = "MMM d"; return d.string(from: date) }()
            meta.append("\(day), \(f.string(from: date))")
        }
        if !duration.isEmpty {
            let mins = Int(SessionSummary.minutes(from: duration).rounded())
            meta.append(mins > 0 ? "\(mins) min" : duration)
        }
        let speakerCount = Set(newLines.map(\.1)).count
        let people = max(participants, speakerCount)
        if people > 1 { meta.append("\(people) people") }
        if !talkShare.isEmpty {
            meta.append(talkShare.replacingOccurrences(of: "% you", with: "% your talk share"))
        }
        metaLine = meta.joined(separator: " · ")

        var share: Double?
        let digits = talkShare.prefix(while: \.isNumber)
        if let pct = Int(digits) { share = Double(pct) / 100 }
        let reviewText = reviewLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        review = reviewText.isEmpty ? nil : MeetingReview.parse(llmText: reviewText, talkShare: share)
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
