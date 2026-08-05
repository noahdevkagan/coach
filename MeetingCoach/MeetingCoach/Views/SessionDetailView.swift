import SwiftUI
import AppKit

/// Saved-session viewer in the main pane — the Dorado 2a redesign: meta
/// line + renameable title + Copy/Export, a collapsible coaching strip,
/// and Transcript / Summary / Coaching tabs. The markdown file on disk
/// stays the source of truth.
struct SessionDetailView: View {
    let url: URL
    /// Active search query — matched terms highlight in the transcript and
    /// the view scrolls to the first hit.
    var highlightQuery: String = ""
    let onClose: () -> Void

    enum Tab: String, CaseIterable {
        case transcript = "Transcript"
        case summary = "Summary"
        case coaching = "Coaching"
    }

    @State private var title = ""
    @State private var metaLine = ""
    @State private var review: MeetingReview?
    @State private var lines: [(stamp: String, speaker: String, text: String)] = []
    @State private var nudgeLines: [String] = []
    @State private var rawContent = ""
    // Default tab. To default to Summary instead, change this one line.
    @State private var tab: Tab = .transcript
    @State private var renaming = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    @AppStorage("coachingStripExpanded") private var stripExpanded = false
    @State private var topPatterns: [(type: NudgeType, count: Int)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .task(id: url) {
            tab = .transcript   // resets per session (spec)
            load()
        }
    }

    // MARK: header — meta, title, actions, coaching strip, tabs

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(metaLine)
                        .font(Dorado.roboto(13))
                        .foregroundStyle(Dorado.grey500)
                    if renaming {
                        TextField("Session title", text: $renameText)
                            .textFieldStyle(.plain)
                            .font(Dorado.barlowXBold(32))
                            .foregroundStyle(Dorado.midnight)
                            .focused($renameFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand { renaming = false }
                    } else {
                        Text(title)
                            .font(Dorado.barlowXBold(32))
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

            if let headline = coachingHeadline {
                coachingStrip(headline)
            }

            tabBar
        }
        .padding(.init(top: 28, leading: 44, bottom: 0, trailing: 44))
    }

    /// Cross-session pattern strip — hidden entirely when there's nothing
    /// to say (spec: no empty state).
    private var coachingHeadline: String? {
        guard let top = topPatterns.first, top.count >= 3 else { return nil }
        return "\(top.type.displayName) keeps coming up — \(top.count)× across your recent sessions"
    }

    private func coachingStrip(_ headline: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15)) {
                    stripExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(Dorado.dorado300)
                        .frame(width: 26, height: 26)
                        .overlay(Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Dorado.midnight))
                    Text(headline)
                        .font(Dorado.roboto(14))
                        .foregroundStyle(Dorado.grey800)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(topPatterns.count) note\(topPatterns.count == 1 ? "" : "s")")
                        .font(Dorado.roboto(13))
                        .foregroundStyle(Dorado.grey600)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(Dorado.grey500)
                        .rotationEffect(.degrees(stripExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if stripExpanded {
                ForEach(Array(topPatterns.enumerated()), id: \.offset) { _, pattern in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Circle()
                            .fill(Dorado.dorado300.opacity(0.35))
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                        Text("\(pattern.type.displayName) — \(pattern.count)× in your recent sessions")
                            .font(Dorado.roboto(15))
                            .foregroundStyle(Dorado.grey800)
                            .lineSpacing(4)
                    }
                }
            }
        }
        .padding(.init(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(RoundedRectangle(cornerRadius: 12).fill(Dorado.warmSurface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Dorado.warmBorder, lineWidth: 1))
    }

    private var tabBar: some View {
        HStack(spacing: 24) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button { tab = t } label: {
                    Text(t.rawValue)
                        .font(Dorado.barlowBold(15))
                        .foregroundStyle(tab == t ? Dorado.midnight : Dorado.grey500)
                        .padding(.bottom, 10)
                        .overlay(alignment: .bottom) {
                            (tab == t ? Dorado.midnight : Color.clear).frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) { Dorado.divider.frame(height: 1) }
    }

    // MARK: tab bodies

    @ViewBuilder
    private var tabBody: some View {
        switch tab {
        case .transcript: transcriptTab
        case .summary: summaryTab
        case .coaching: coachingTab
        }
    }

    private var transcriptTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
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
                .padding(.init(top: 20, leading: 44, bottom: 0, trailing: 44))
            }
            .mask(
                // Bottom scroll fade over the last ~40px (spec).
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 40)
                }
            )
            .onAppear { scrollToFirstHit(proxy) }
            .onChange(of: highlightQuery) { _, _ in scrollToFirstHit(proxy) }
        }
    }

    private var summaryTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let review {
                    MeetingReviewView(review: review) { id in
                        toggleActionItem(id)
                    }
                } else {
                    Text("No summary yet — reviews generate at the end of a coached session.")
                        .font(Dorado.roboto(13)).foregroundStyle(Dorado.grey400)
                }
            }
            .padding(.init(top: 20, leading: 44, bottom: 20, trailing: 44))
        }
    }

    private var coachingTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(nudgeLines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Circle()
                            .fill(Dorado.dorado300)
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                        Text(line)
                            .font(Dorado.roboto(15))
                            .foregroundStyle(Dorado.grey800)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                    }
                }
                if nudgeLines.isEmpty {
                    Text("No coaching nudges fired in this session.")
                        .font(Dorado.roboto(13)).foregroundStyle(Dorado.grey400)
                }
            }
            .padding(.init(top: 20, leading: 44, bottom: 20, trailing: 44))
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
            metaLine = ""; review = nil; lines = []; nudgeLines = []; rawContent = ""
            return
        }
        rawContent = content
        title = TranscriptSearch.headerTitle(in: content) ?? TranscriptSearch.title(for: url)

        var duration = ""
        var talkShare = ""
        var participants = 0
        var newLines: [(String, String, String)] = []
        var newNudges: [String] = []
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
            if section.hasPrefix("## Nudges") {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    newNudges.append(String(trimmed.dropFirst(2)))
                }
                continue
            }
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
        nudgeLines = newNudges

        // "Today, 9:00 AM · 32 min · 4 people · 41% your talk share"
        var meta: [String] = []
        if let date = DoradoRail.sessionDate(url) {
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

        topPatterns = SessionTrends.topPatterns(from: SessionTrends.loadAll(), limit: 3)
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
