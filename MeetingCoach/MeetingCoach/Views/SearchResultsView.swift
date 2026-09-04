import SwiftUI

/// Full-text results over every saved chat: type in the sidebar box, see
/// each moment a word was said, jump to the session file. Grouped by
/// session, newest first — the payoff for "transcript is the product."
/// Multi-word queries match all words in any order, and an "Ask AI" card
/// lets the local model answer the query as a question across meetings.
struct SearchResultsView: View {
    let query: String
    /// Present = the Ask AI card can run the local model (same on-demand
    /// policy as "Generate AI review" on a saved session).
    var settings: SettingsViewModel?
    var ollamaManager: OllamaManager?
    /// Open a session — the host decides where (main-pane viewer).
    var onOpen: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @State private var hits: [TranscriptHit] = []

    private enum AskState: Equatable {
        case idle
        /// The message says what the wait actually is — "loading the
        /// model" on a cold first ask vs "reading your meetings" when warm.
        case thinking(String)
        case answered(String, [MeetingAskSource])
        /// One line on WHY there's no answer — degraded modes stay visible.
        case unavailable(String)
    }
    @State private var askState: AskState = .idle
    @State private var askTick = 0
    /// The query an in-flight/finished answer belongs to — typing on
    /// invalidates it.
    @State private var askedQuery = ""

    private var groups: [(file: URL, title: String, hits: [TranscriptHit])] {
        var order: [URL] = []
        var byFile: [URL: [TranscriptHit]] = [:]
        for hit in hits {
            if byFile[hit.file] == nil { order.append(hit.file) }
            byFile[hit.file, default: []].append(hit)
        }
        return order.map {
            (file: $0,
             title: byFile[$0]?.first?.sessionTitle ?? TranscriptSearch.title(for: $0),
             hits: byFile[$0] ?? [])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Search")
                    .font(MCTheme.paneTitle)
                Text("“\(query)”")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if !hits.isEmpty {
                    Text("\(groups.count) chats · \(hits.count) mentions")
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if settings != nil, ollamaManager != nil {
                        askCard
                    }
                    if hits.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "text.magnifyingglass")
                                .font(.title2).foregroundStyle(.tertiary)
                            Text("No mentions of “\(query)” in saved chats")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                    ForEach(groups, id: \.file) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(group.title)
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Open") {
                                    onOpen(group.file)
                                }
                                .font(.caption)
                                .buttonStyle(.plain)
                                .foregroundStyle(.blue)
                                .help("Open the saved transcript")
                            }
                            ForEach(group.hits) { hit in
                                // Timestamp-less hits are title matches
                                // (the chat's name, not a spoken line).
                                if hit.timestamp.isEmpty {
                                    Text("Matches the chat name")
                                        .font(.caption2.italic())
                                        .foregroundStyle(.tertiary)
                                } else {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(hit.timestamp)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                        Text(hit.speaker)
                                            .font(.caption2.bold())
                                            .foregroundStyle(hit.speaker == "You" ? .blue : .purple)
                                        Text(highlighted(hit.text))
                                            .font(.callout)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .cardStyle(cornerRadius: 10)
                    }
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MCTheme.canvas)
        .task(id: query) {
            hits = TranscriptSearch.search(query)
            // A new query invalidates the previous answer, not any run
            // already in flight for the same words.
            if askedQuery != query { askState = .idle }
        }
        .task(id: askTick) {
            guard askTick > 0 else { return }
            await runAsk()
        }
    }

    // MARK: - Ask AI

    /// The Granola-style layer over word search: the local model reads the
    /// best-matching sessions and answers the query as a question.
    @ViewBuilder
    private var askCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch askState {
            case .idle:
                Button {
                    askedQuery = query
                    askTick += 1
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles")
                            .font(.caption).foregroundStyle(.blue)
                        Text("Ask AI: “\(query)”")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text("answers from your meetings, on this Mac")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("The local model reads the matching meetings and answers — nothing leaves this Mac")
            case .thinking(let message):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message)
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .answered(let answer, let sources):
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.caption).foregroundStyle(.blue)
                    Text("AI answer")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    CopyButton(help: "Copy the answer") { answer }
                }
                Text(answer)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !sources.isEmpty {
                    HStack(spacing: 6) {
                        Text("From:")
                            .font(.caption2).foregroundStyle(.tertiary)
                        ForEach(sources) { source in
                            Button {
                                onOpen(source.file)
                            } label: {
                                Text(source.date.isEmpty
                                     ? source.title
                                     : "\(source.title) · \(source.date)")
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                            .help("Open this meeting")
                        }
                    }
                }
            case .unavailable(let why):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(why)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .cardStyle(cornerRadius: 10)
    }

    private func runAsk() async {
        guard let settings, let ollamaManager else { return }
        let question = query
        askState = .thinking("Reading your meetings with the local model…")

        let (excerpts, sources) = MeetingAsk.buildContext(question: question)
        guard !sources.isEmpty else {
            if question == query {
                askState = .unavailable(
                    "None of your saved meetings mention these words — the AI has nothing to read.")
            }
            return
        }

        // Same on-demand model dance as "Generate AI review".
        if ollamaManager.status == .stopped { ollamaManager.start() }
        if ollamaManager.status != .running {
            for _ in 1...30 {
                try? await Task.sleep(for: .milliseconds(500))
                if ollamaManager.status == .running { break }
                if case .error = ollamaManager.status { break }
            }
        }
        await settings.refreshModels()
        guard ollamaManager.status == .running, !settings.availableModels.isEmpty else {
            if question == query {
                askState = .unavailable(
                    "AI answers need a local model (Settings → Model) — showing word matches only.")
            }
            return
        }

        let (system, user) = MeetingAsk.prompt(question: question, excerpts: excerpts)
        do {
            // 4096/384 (not the defaults): the ~7k-char excerpt budget plus
            // a 180-word answer fits comfortably, a smaller context spawns
            // the runner faster on a cold ask, and 4096 matches the in-call
            // phase so a warm live-session runner is reused, not respawned.
            let client = OllamaClient(model: settings.effectiveModel,
                                      numCtx: 4096, numPredict: 384)
            if await !client.runningModels().contains(settings.effectiveModel),
               question == query {
                askState = .thinking(
                    "Loading \(settings.effectiveModel) — the first question pays this once, repeats are much faster…")
            }
            let text = try await client.complete(system: system, user: user)
            let cleaned = text.components(separatedBy: .newlines)
                .map(MeetingReview.clean)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard question == query else { return }
            askState = cleaned.isEmpty
                ? .unavailable("The local model returned nothing — try asking again.")
                : .answered(cleaned, sources)
        } catch {
            guard question == query else { return }
            askState = .unavailable("The local model couldn't answer (\(error.localizedDescription)) — word matches below still work.")
        }
    }

    /// Every query word in semibold — enough emphasis to scan, calm
    /// enough to read.
    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        for token in TranscriptSearch.queryTokens(query) {
            var searchStart = attributed.startIndex
            while let range = attributed[searchStart...].range(
                of: token, options: [.caseInsensitive, .diacriticInsensitive]) {
                attributed[range].font = .callout.weight(.semibold)
                attributed[range].foregroundColor = .blue
                searchStart = range.upperBound
            }
        }
        return attributed
    }
}
