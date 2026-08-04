import SwiftUI
import AppKit

// MARK: - Dorado design tokens (2a "Merged" redesign, 2026-08-04 handoff)

/// The handoff's token table, verbatim. Light-only by design — the window
/// forces light appearance while this is the shipped look.
enum Dorado {
    // Color
    static let dorado300 = Color(hex: 0xFFBC00)   // Go live, coaching badge
    static let dorado100 = Color(hex: 0xFFEE4E)   // hover, active highlight
    static let dorado500 = Color(hex: 0xF58A00)   // pressed
    static let doradoTint = Color(hex: 0xFFF3CC)  // inactive-row highlight
    static let bolt = Color(hex: 0x0044C0)        // "You", links
    static let dollar = Color(hex: 0x00C838)      // model-loaded dot
    static let midnight = Color(hex: 0x021414)    // headings, focus ring
    static let grey800 = Color(hex: 0x3C4552)     // body text
    static let grey600 = Color(hex: 0x647184)     // secondary text
    static let grey500 = Color(hex: 0x8B96A5)     // labels, icons, meta
    static let grey400 = Color(hex: 0xA6AFBB)     // timestamps, dates
    static let border = Color(hex: 0xDDE2E8)      // outline buttons
    static let divider = Color(hex: 0xEDEFF2)     // rail border, tab rule
    static let surfaceSubtle = Color(hex: 0xF5F7F9) // search field, selection
    static let warmSurface = Color(hex: 0xFCFBF8) // coaching strip bg
    static let warmBorder = Color(hex: 0xF1EDE4)  // coaching strip border

    // Type — bundled faces (Resources/Fonts, ATSApplicationFontsPath).
    // Font.custom silently falls back to the system face if a TTF ever
    // fails to register, so a font problem degrades instead of breaking.
    static func barlowBold(_ size: CGFloat) -> Font { .custom("Barlow-Bold", size: size) }
    static func barlowXBold(_ size: CGFloat) -> Font { .custom("Barlow-ExtraBold", size: size) }
    static func roboto(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Roboto", size: size).weight(weight)
    }
    static func mono(_ size: CGFloat) -> Font { .custom("Roboto Mono", size: size) }
    /// 11px all-caps label with 0.1em tracking — the only sub-12px style.
    static func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(roboto(11, .bold))
            .kerning(1.1)
            .foregroundStyle(grey500)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Go live / stop pill — the app's single primary action.
/// Hover #FFEE4E, press #F58A00, no scale transform (spec).
struct DoradoPillButtonStyle: ButtonStyle {
    var stop = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Dorado.barlowBold(16))
            .foregroundStyle(stop ? Color.white : Dorado.midnight)
            .frame(maxWidth: .infinity)
            .padding(13)
            .background(background(pressed: configuration.isPressed))
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15), value: hovering)
    }

    private func background(pressed: Bool) -> Color {
        if stop { return pressed ? Dorado.grey800 : Dorado.midnight }
        if pressed { return Dorado.dorado500 }
        return hovering ? Dorado.dorado100 : Dorado.dorado300
    }
}

/// Copy / Export outline pill (1px #DDE2E8, hover border #021414).
struct DoradoOutlineButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Dorado.roboto(13, .medium))
            .foregroundStyle(Dorado.grey800)
            .padding(.vertical, 8).padding(.horizontal, 15)
            .background(Capsule().strokeBorder(hovering ? Dorado.midnight : Dorado.border, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15), value: hovering)
    }
}

// MARK: - Left rail

/// One saved session as the rail lists it.
struct RailSession: Identifiable {
    let url: URL
    let title: String
    let date: Date?
    var id: URL { url }

    /// "Today" / "Aug 2" — the mockup's compact date column.
    var dateLabel: String {
        guard let date else { return "" }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

/// A search hit group for the MATCHES IN TRANSCRIPTS list.
struct RailMatch: Identifiable {
    let url: URL
    let title: String
    let dateLabel: String
    let snippet: String     // one line, term visible
    let hitCount: Int
    var id: URL { url }
}

struct DoradoRail: View {
    @Bindable var simulation: SimulationViewModel
    @Bindable var settings: SettingsViewModel
    @Bindable var liveSession: LiveSessionViewModel
    @Bindable var ollamaManager: OllamaManager
    @Binding var searchQuery: String
    @Binding var selectedSession: URL?
    var onToggleOverlay: () -> Void

    @State private var sessions: [RailSession] = []
    @State private var matches: [RailMatch] = []
    @State private var searchDebounce: Task<Void, Never>?
    @State private var showQuestions = false
    @State private var showCoachingNotes = false
    @State private var showModel = false
    @AppStorage("sidebarAdvancedExpanded") private var advancedExpanded = true
    @FocusState private var searchFocused: Bool

    private var query: String {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        return q.count >= 2 ? q : ""
    }

    var body: some View {
        VStack(spacing: 0) {
            topBlock
            sessionList
            advancedBlock
        }
        .frame(width: 288)
        .overlay(alignment: .trailing) { Dorado.divider.frame(width: 1) }
        .background(Color.white)
        .task { reload() }
        .onChange(of: liveSession.showPostSession) { _, _ in reload() }
        .onChange(of: liveSession.isLive) { _, live in if !live { reload() } }
        .onChange(of: searchQuery) { _, _ in
            searchDebounce?.cancel()
            searchDebounce = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                refreshMatches()
            }
        }
        .onExitCommand { searchQuery = "" }
    }

    // MARK: top block — Go live + search

    private var topBlock: some View {
        VStack(spacing: 12) {
            if liveSession.isLive || liveSession.hasSession {
                // Live + post-session controls stay the proven pre-redesign
                // block (status, silence warning, stop, overlay toggle,
                // keep/delete, review) — the handoff explicitly left the
                // live state undesigned and said not to invent one.
                LiveSection(liveSession: liveSession,
                            settings: settings,
                            onToggleOverlay: onToggleOverlay,
                            ollamaManager: ollamaManager)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Dorado.surfaceSubtle))
            } else {
                Button {
                    liveSession.startLive(context: liveSession.preCallContext,
                                          settings: settings,
                                          ollamaManager: ollamaManager)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 14, weight: .bold))
                        Text("Go live")
                    }
                }
                .buttonStyle(DoradoPillButtonStyle())
                .help("Listens to your meeting audio and coaches you in real time. Transcript saves automatically.")
                .sheet(isPresented: $liveSession.showPreCallForm) {
                    PreCallFormView(context: $liveSession.preCallContext) {
                        liveSession.startLive(context: liveSession.preCallContext,
                                              settings: settings,
                                              ollamaManager: ollamaManager)
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Dorado.grey500)
                TextField("Search transcripts", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(Dorado.roboto(13))
                    .foregroundStyle(Dorado.grey800)
                    .focused($searchFocused)
                if !query.isEmpty {
                    let hits = matches.reduce(0) { $0 + $1.hitCount }
                    Text("\(hits) hit\(hits == 1 ? "" : "s")")
                        .font(Dorado.roboto(11))
                        .foregroundStyle(Dorado.grey500)
                }
            }
            .padding(.vertical, 9).padding(.horizontal, 11)
            .background(RoundedRectangle(cornerRadius: 8).fill(Dorado.surfaceSubtle))
        }
        .padding(.init(top: 4, leading: 16, bottom: 14, trailing: 16))
    }

    // MARK: session list

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !query.isEmpty {
                    Dorado.sectionLabel("MATCHES IN TRANSCRIPTS")
                        .padding(.init(top: 6, leading: 8, bottom: 6, trailing: 8))
                    if matches.isEmpty {
                        Text("No matches")
                            .font(Dorado.roboto(12))
                            .foregroundStyle(Dorado.grey400)
                            .padding(.horizontal, 10)
                    }
                    ForEach(matches) { match in
                        matchRow(match)
                    }
                    Dorado.sectionLabel("ALL SESSIONS")
                        .padding(.init(top: 16, leading: 8, bottom: 6, trailing: 8))
                }
                ForEach(sessions) { session in
                    sessionRow(session)
                }
                if sessions.isEmpty && query.isEmpty {
                    Text("Sessions appear here after your first meeting")
                        .font(Dorado.roboto(12))
                        .foregroundStyle(Dorado.grey400)
                        .padding(10)
                }
            }
            .padding(.init(top: 0, leading: 8, bottom: 8, trailing: 8))
        }
        .frame(maxHeight: .infinity)
    }

    private func matchRow(_ match: RailMatch) -> some View {
        let selected = selectedSession == match.url
        return Button {
            selectedSession = match.url
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(match.title)
                        .font(Dorado.barlowBold(15))
                        .foregroundStyle(selected ? Dorado.midnight : Dorado.grey800)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(match.dateLabel)
                        .font(Dorado.roboto(11))
                        .foregroundStyle(selected ? Dorado.grey500 : Dorado.grey400)
                }
                highlightedSnippet(match.snippet, selected: selected)
                    .font(Dorado.roboto(12))
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(RailRowButtonStyle(selected: selected))
    }

    private func sessionRow(_ session: RailSession) -> some View {
        let selected = selectedSession == session.url && query.isEmpty
        return Button {
            selectedSession = session.url
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title)
                    .font(Dorado.barlowBold(15))
                    .foregroundStyle(selected ? Dorado.midnight : Dorado.grey800)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(session.dateLabel)
                    .font(Dorado.roboto(11))
                    .foregroundStyle(Dorado.grey400)
            }
            .padding(.vertical, 9).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(RailRowButtonStyle(selected: selected))
        .contextMenu {
            Button("Rename…") { renameTarget = session }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([session.url])
            }
        }
        .alert("Rename chat", isPresented: showingRename(for: session)) {
            TextField("Person · subject", text: $renameText)
            Button("Save") {
                TranscriptSearch.setTitle(renameText, for: session.url)
                renameTarget = nil
                reload()
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Shown in the sessions list instead of the date. Clear it to go back to the date.")
        }
    }

    @State private var renameTarget: RailSession?
    @State private var renameText = ""

    private func showingRename(for session: RailSession) -> Binding<Bool> {
        Binding(
            get: { renameTarget?.url == session.url },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    /// Match snippet with the query term in the spec's highlight colors.
    private func highlightedSnippet(_ snippet: String, selected: Bool) -> Text {
        var attributed = AttributedString(snippet)
        attributed.foregroundColor = selected ? Dorado.grey600 : Dorado.grey500
        if let range = attributed.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[range].backgroundColor = selected ? Dorado.dorado100 : Dorado.doradoTint
            attributed[range].foregroundColor = selected ? Dorado.midnight : Dorado.grey800
        }
        return Text(attributed)
    }

    // MARK: Advanced block

    private var advancedBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15)) {
                    advancedExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(advancedExpanded ? 0 : -90))
                    Dorado.sectionLabel("ADVANCED")
                    Spacer()
                }
                .foregroundStyle(Dorado.grey500)
                .padding(.init(top: 6, leading: 6, bottom: 4, trailing: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if advancedExpanded {
                advancedRow(icon: "checklist", label: "Questions to ask") { showQuestions = true }
                    .popover(isPresented: $showQuestions, arrowEdge: .trailing) {
                        ScrollView { PlannedQuestionsSection().padding(14) }
                            .frame(width: 340, height: 320)
                    }
                advancedRow(icon: "square.and.pencil", label: "Coaching notes") { showCoachingNotes = true }
                    .popover(isPresented: $showCoachingNotes, arrowEdge: .trailing) {
                        ScrollView {
                            FeedbackSection(simulation: simulation, liveSession: liveSession,
                                            settings: settings, ollamaManager: ollamaManager)
                                .padding(14)
                        }
                        .frame(width: 360, height: 380)
                    }
                modelRow
                if case .error = ollamaManager.status {
                    OllamaStatusBar(manager: ollamaManager)
                }
                if let model = settings.downloadingModel {
                    downloadRow(model)
                }
            }

            Text(SidebarView.versionLabel)
                .font(Dorado.mono(10))
                .foregroundStyle(Dorado.grey400.opacity(0.7))
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
        }
        .padding(.init(top: 10, leading: 12, bottom: 12, trailing: 12))
        .overlay(alignment: .top) { Dorado.divider.frame(height: 1) }
    }

    private func advancedRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Dorado.grey500)
                    .frame(width: 16)
                Text(label)
                    .font(Dorado.roboto(14))
                    .foregroundStyle(Dorado.grey800)
                Spacer()
            }
            .padding(.vertical, 9).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RailRowButtonStyle(selected: false))
    }

    /// The app's only status indicator: green dot = engine running with the
    /// selected model, grey = not available.
    private var modelRow: some View {
        Button { showModel = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .font(.system(size: 12))
                    .foregroundStyle(Dorado.grey500)
                    .frame(width: 16)
                Text("Model")
                    .font(Dorado.roboto(14))
                    .foregroundStyle(Dorado.grey800)
                Spacer()
                Text(settings.selectedModel)
                    .font(Dorado.mono(12))
                    .foregroundStyle(Dorado.grey500)
                    .lineLimit(1)
                Circle()
                    .fill(modelLoaded ? Dorado.dollar : Color(hex: 0xC7CED7))
                    .frame(width: 7, height: 7)
            }
            .padding(.vertical, 9).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RailRowButtonStyle(selected: false))
        .popover(isPresented: $showModel, arrowEdge: .trailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ModelSection(settings: settings)
                    Text("AI nudges and the meeting summary switch on automatically when a model is installed.")
                        .font(Dorado.roboto(12))
                        .foregroundStyle(Dorado.grey500)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }
            .frame(width: 340, height: 300)
        }
    }

    private var modelLoaded: Bool {
        if case .running = ollamaManager.status { return true }
        return false
    }

    private func downloadRow(_ model: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Downloading \(model)…")
                .font(Dorado.roboto(12))
                .foregroundStyle(Dorado.grey600)
            ProgressView(value: settings.downloadProgress)
                .controlSize(.small)
                .tint(Dorado.dorado300)
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
    }

    // MARK: data

    private func reload() {
        sessions = TranscriptSearch.sessionFiles().map { url in
            var title = TranscriptSearch.headerTitle(at: url)
            if title == nil,
               let content = try? String(contentsOf: url, encoding: .utf8),
               !TranscriptSearch.hasTitleLine(in: content),
               let suggested = TranscriptSearch.suggestedTitle(in: content) {
                // Same auto-title write-back the old sidebar did, so search
                // and the dashboard agree with the rail.
                TranscriptSearch.setTitle(suggested, for: url)
                title = suggested
            }
            return RailSession(url: url,
                               title: title ?? TranscriptSearch.title(for: url),
                               date: Self.sessionDate(url))
        }
        refreshMatches()
    }

    private func refreshMatches() {
        guard !query.isEmpty else { matches = []; return }
        let hits = TranscriptSearch.search(query)
        var order: [URL] = []
        var grouped: [URL: [TranscriptHit]] = [:]
        for hit in hits {
            if grouped[hit.file] == nil { order.append(hit.file) }
            grouped[hit.file, default: []].append(hit)
        }
        matches = order.map { url in
            let sessionHits = grouped[url] ?? []
            let spoken = sessionHits.filter { !$0.timestamp.isEmpty }
            let snippet: String
            if spoken.count > 1 {
                snippet = "…\(spoken.count) matches for \(query)…"
            } else if let first = spoken.first {
                snippet = "…\(first.text.prefix(90))…"
            } else {
                snippet = "Matches the chat name"
            }
            return RailMatch(url: url,
                             title: sessionHits.first?.sessionTitle ?? TranscriptSearch.title(for: url),
                             dateLabel: RailSession(url: url, title: "", date: Self.sessionDate(url)).dateLabel,
                             snippet: snippet,
                             hitCount: sessionHits.count)
        }
    }

    /// Parse the canonical date out of "session_yyyy-MM-dd_HH-mm.md".
    static func sessionDate(_ url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("session_") else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return f.date(from: String(name.dropFirst("session_".count)))
    }
}

/// Hover #F5F7F9, selected #F5F7F9 — the rail's one row treatment.
struct RailRowButtonStyle: ButtonStyle {
    var selected: Bool
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected || hovering ? Dorado.surfaceSubtle : .clear)
            )
            .onHover { hovering = $0 }
            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15), value: hovering)
    }
}
