import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var ollamaManager: OllamaManager
    @State private var simulation = SimulationViewModel()
    @State private var settings = SettingsViewModel()
    @State private var liveSession = LiveSessionViewModel()
    @State private var overlayPanel: CoachingOverlayPanel?
    @AppStorage("hasSeenDemo") private var hasSeenDemo = false
    @State private var showWelcome = false

    var body: some View {
        HSplitView {
            // Left sidebar
            VStack(spacing: 0) {
                SidebarView(simulation: simulation, settings: settings,
                            liveSession: liveSession, ollamaManager: ollamaManager,
                            onToggleOverlay: toggleOverlay)
            }
            .frame(minWidth: 280, idealWidth: 300, maxWidth: 340)

            // Main content — live session, loaded transcript, or progress
            if liveSession.isLive || liveSession.hasSession {
                LiveTimelineView(liveSession: liveSession)
                    .frame(minWidth: 400)
            } else if simulation.transcriptFileName != nil {
                SimulationTimelineView(simulation: simulation)
                    .frame(minWidth: 400)
            } else {
                ProgressDashboardView(liveSession: liveSession)
                    .frame(minWidth: 400)
            }
        }
        .task {
            // No longer wait for Ollama before allowing app use.
            // Refresh models in background for when post-call review is needed.
            settings.ollamaManager = ollamaManager
            // Fetch the transcription model off the critical path so the
            // first real session starts on Parakeet instead of the fallback.
            ParakeetEngine.prefetchInBackground()
            if !hasSeenDemo { showWelcome = true }
            await settings.refreshModels()
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeSheet {
                hasSeenDemo = true
                showWelcome = false
                liveSession.startDemo()
            } onSkip: {
                hasSeenDemo = true
                showWelcome = false
            }
        }
        .onChange(of: liveSession.isLive) { _, isLive in
            if isLive { showOverlay() } else { hideOverlay() }
        }
    }

    private func toggleOverlay() {
        if overlayPanel?.isVisible == true {
            hideOverlay()
        } else {
            showOverlay()
        }
    }

    private func showOverlay() {
        if overlayPanel == nil {
            overlayPanel = CoachingOverlayPanel()
        }
        updateOverlay()
        overlayPanel?.orderFront(nil)
    }

    private func hideOverlay() {
        overlayPanel?.orderOut(nil)
    }

    private func updateOverlay() {
        guard let panel = overlayPanel, panel.isVisible else { return }
        // The view observes the session (@Observable), so one hosting view
        // tracks nudges and the talk meter without being rebuilt.
        let view = CoachingOverlayView(liveSession: liveSession) { [weak panel = overlayPanel] in
            panel?.orderOut(nil)
        }
        panel.contentView = NSHostingView(rootView: view)
    }
}

// MARK: - Live Timeline View

struct LiveTimelineView: View {
    @Bindable var liveSession: LiveSessionViewModel

    var body: some View {
        HSplitView {
            // Left: nudges feed
            nudgesPanel
                .frame(minWidth: 280)

            // Right: live transcript
            transcriptPanel
                .frame(minWidth: 220, idealWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.textBackgroundColor))
    }

    private var nudgesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Nudges")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if !liveSession.nudges.isEmpty {
                    Text("\(liveSession.nudges.count)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.blue.opacity(0.1)).foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal).padding(.vertical, 8)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        // Summary card
                        if let summary = liveSession.meetingSummary {
                            MeetingSummaryCard(summary: summary, recapText: recapText(summary))
                                .id("summary")
                            Divider().padding(.vertical, 4)
                        } else if liveSession.isGeneratingSummary {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Generating review...").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 4).id("summary-loading")
                        }

                        // Nudge feed
                        if liveSession.nudges.isEmpty {
                            VStack(spacing: 8) {
                                if liveSession.isLive {
                                    Image(systemName: "waveform.badge.mic")
                                        .font(.system(size: 28))
                                        .foregroundStyle(.green.opacity(0.4))
                                        .symbolEffect(.pulse)
                                    Text("Listening for patterns...")
                                        .font(.caption).foregroundStyle(.tertiary)
                                } else if liveSession.hasSession {
                                    Text("Session ended").font(.caption).foregroundStyle(.tertiary)
                                } else {
                                    Text("Go live to start scanning")
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        }

                        ForEach(liveSession.nudges) { nudge in
                            NudgeCardView(nudge: nudge) { feedback in
                                liveSession.recordFeedback(nudgeId: nudge.id, feedback: feedback)
                            }
                            .id(nudge.id)
                        }

                        Color.clear.frame(height: 1).id("feed-bottom")
                    }
                    .padding()
                }
                .onChange(of: liveSession.nudges.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("feed-bottom")
                    }
                }
            }
        }
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if liveSession.isLive {
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
                Text("Live Transcript")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                TranscriptHeaderStats(liveSession: liveSession)
                if !liveSession.isLive && liveSession.hasSession && !liveSession.turns.isEmpty {
                    Button {
                        exportTranscript()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Export transcript as a text file")
                }
            }
            .padding(.horizontal).padding(.vertical, 8)

            // Talk balance: rolling share bar + session sparkline
            if let share = liveSession.talkStats.recentShare ?? liveSession.talkStats.sessionShare {
                TalkBalanceHeader(share: share, history: liveSession.talkStats.history)
                    .padding(.horizontal).padding(.bottom, 6)
            }
            Divider()

            LiveTranscriptPane(liveSession: liveSession)
        }
        .background(Color(.controlBackgroundColor).opacity(0.5))
    }

    private func recapText(_ summary: String) -> String {
        RecapExporter.markdown(
            summary: summary,
            context: liveSession.preCallContext,
            durationMinutes: max(1, Int(liveSession.elapsedTime) / 60),
            talkShare: liveSession.talkStats.sessionShare
        )
    }

    private func exportTranscript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        panel.nameFieldStringValue = "transcript_\(formatter.string(from: Date())).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = liveSession.turns
            .map { "[\($0.formattedTime)] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Talk balance strip for the transcript panel: the meter bar plus a small
/// sparkline of how the share moved across the session.
private struct TalkBalanceHeader: View {
    let share: Double
    let history: [TalkStats.Sample]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TalkMeterBar(share: share)
            if history.count >= 4 {
                TalkShareSparkline(history: history)
                    .frame(height: 14)
            }
        }
    }
}

/// Minimal line sparkline of talk share over time; the 65% warn level is a
/// faint reference line.
private struct TalkShareSparkline: View {
    let history: [TalkStats.Sample]
    var warnAt: Double = 0.65

    var body: some View {
        GeometryReader { geo in
            let minT = history.first?.t ?? 0
            let maxT = max(history.last?.t ?? 1, minT + 1)
            let points = history.map { sample in
                CGPoint(
                    x: geo.size.width * (sample.t - minT) / (maxT - minT),
                    y: geo.size.height * (1 - sample.share)
                )
            }
            ZStack {
                Path { p in
                    let y = geo.size.height * (1 - warnAt)
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
                .stroke(Color.orange.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    for pt in points.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(Color.blue.opacity(0.7), lineWidth: 1.5)
            }
        }
    }
}

/// Isolated so the 1-second clock tick only re-renders these two Texts,
/// not the whole transcript panel.
private struct TranscriptHeaderStats: View {
    var liveSession: LiveSessionViewModel

    var body: some View {
        Text("\(liveSession.utterances.count) lines")
            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        Text(liveSession.elapsedFormatted)
            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
    }
}

/// Renders the pre-built turns from the view model — no per-frame re-joining,
/// stable identity per turn.
private struct LiveTranscriptPane: View {
    var liveSession: LiveSessionViewModel

    /// Pending recognizer text, stable order (You before Them).
    private var pendingLines: [(speaker: String, text: String)] {
        liveSession.livePartials
            .sorted { $0.key < $1.key }
            .map { (speaker: $0.key, text: $0.value) }
            .reversed()
    }

    var body: some View {
        if liveSession.turns.isEmpty && pendingLines.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.title2).foregroundStyle(.tertiary)
                Text("Speak to see your\ntranscript appear here")
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // Plain VStack, NOT LazyVStack: lazy layout caches row
                    // positions, and removing the tall pending row when it
                    // commits leaves phantom blank space mid-list (Parakeet
                    // partials grow into full paragraphs, so the hole is big).
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(liveSession.turns) { turn in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(turn.formattedTime)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                    Text(turn.speaker)
                                        .font(.caption2.bold())
                                        .foregroundStyle(speakerColor(turn.speaker))
                                }
                                Text(turn.text)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        // Live pending line(s): what the recognizer hears right
                        // now, before it's committed as a turn — dictation feel.
                        ForEach(pendingLines, id: \.speaker) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                if line.speaker != "Meeting" {
                                    Text(line.speaker)
                                        .font(.caption2.bold())
                                        .foregroundStyle(speakerColor(line.speaker).opacity(0.6))
                                }
                                Text(line.text)
                                    .font(.callout.italic())
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Color.clear.frame(height: 1).id("transcript-bottom")
                    }
                    .padding(12)
                }
                .onChange(of: liveSession.turns.count) { _, _ in
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
                .onChange(of: liveSession.turns.last?.text) { _, _ in
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
                .onChange(of: pendingLines.first?.text) { _, _ in
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Nudge Card View

struct NudgeCardView: View {
    let nudge: Nudge
    let onFeedback: (NudgeFeedback) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Timestamp
            Text(nudge.formattedTime)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            // Urgency indicator
            Circle()
                .fill(urgencyColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(nudge.text)
                    .font(.system(.body, weight: .semibold))

                HStack(spacing: 8) {
                    // Type badge
                    Text(nudge.badgeLabel)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(urgencyColor.opacity(0.15))
                        .foregroundStyle(urgencyColor)
                        .clipShape(Capsule())

                    // Urgency label
                    Text(nudge.urgency.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer()

                }

                // Feedback row — prominent buttons or result
                if let feedback = nudge.feedback {
                    HStack(spacing: 6) {
                        Image(systemName: feedbackIcon(feedback))
                            .font(.caption)
                        Text(feedbackLabel(feedback))
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                } else {
                    HStack(spacing: 8) {
                        feedbackButton(.useful, label: "Useful", icon: "hand.thumbsup.fill", color: .green)
                        feedbackButton(.annoying, label: "Meh", icon: "minus.circle.fill", color: .gray)
                        feedbackButton(.wrong, label: "Wrong", icon: "xmark.circle.fill", color: .red)
                    }
                    .padding(.top, 4)
                }
            }

            Spacer()
        }
        .padding(10)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func feedbackButton(_ feedback: NudgeFeedback, label: String, icon: String, color: Color) -> some View {
        Button {
            onFeedback(feedback)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func feedbackLabel(_ feedback: NudgeFeedback) -> String {
        switch feedback {
        case .useful: return "Useful"
        case .annoying: return "Meh"
        case .wrong: return "Wrong"
        }
    }

    private func feedbackIcon(_ feedback: NudgeFeedback) -> String {
        switch feedback {
        case .useful: return "hand.thumbsup.fill"
        case .annoying: return "minus.circle.fill"
        case .wrong: return "xmark.circle.fill"
        }
    }

    private var urgencyColor: Color {
        if nudge.type.isPositive { return .green }
        switch nudge.urgency {
        case .low: return .gray
        case .med: return .blue
        case .high: return .orange
        }
    }
}

struct MeetingSummaryCard: View {
    let summary: String
    /// Full shareable recap (summary + session facts + footer). When set,
    /// copy/share controls appear in the card header.
    var recapText: String?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Meeting Review", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                if let recap = recapText {
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Button {
                        RecapExporter.copyToPasteboard(recap)
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy recap for Slack or email")

                    ShareLink(item: recap) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Share recap")
                }
            }

            Text(summary)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.blue.opacity(0.15), lineWidth: 1)
        )
    }
}

struct SidebarView: View {
    @Bindable var simulation: SimulationViewModel
    @Bindable var settings: SettingsViewModel
    @Bindable var liveSession: LiveSessionViewModel
    @Bindable var ollamaManager: OllamaManager
    var onToggleOverlay: () -> Void
    @State private var isDragOver = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Engine auto-starts when Go Live / review needs it,
                    // so only surface transient or error states here
                    switch ollamaManager.status {
                    case .stopped, .running:
                        EmptyView()
                    case .starting, .error:
                        OllamaStatusBar(manager: ollamaManager)
                    }

                    // Live coaching — the main feature
                    LiveSection(liveSession: liveSession,
                                settings: settings,
                                onToggleOverlay: onToggleOverlay,
                                ollamaManager: ollamaManager)

                    Divider()
                    CoachingStyleSection(settings: settings, ollamaManager: ollamaManager)
                    Divider()
                    TranscriptSection(simulation: simulation, isDragOverEntireView: isDragOver)
                    Divider()
                    FeedbackSection(simulation: simulation, liveSession: liveSession)
                    Divider()
                    ModelSection(settings: settings)
                }
                .padding()
            }
            .background(isDragOver ? Color.blue.opacity(0.04) : .clear)
            .background(.background)
            .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
                handleDrop(providers, simulation: simulation)
            }

            Divider()
            // Real bundle version (stamped from the release tag by CI) — never
            // hardcode here again; a stale footer in an auto-updating app is
            // worse than none.
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.quaternary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], simulation: SimulationViewModel) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
            guard let data = data as? Data,
                  let path = String(data: data, encoding: .utf8),
                  let url = URL(string: path) else { return }
            let ext = url.pathExtension.lowercased()
            guard ["txt", "md", "text"].contains(ext) else { return }
            DispatchQueue.main.async {
                simulation.loadTranscript(from: url)
            }
        }
        return true
    }
}

// MARK: - Ollama Status Bar

struct OllamaStatusBar: View {
    @Bindable var manager: OllamaManager

    var body: some View {
        HStack(spacing: 6) {
            switch manager.status {
            case .stopped:
                Image(systemName: "circle.fill").foregroundStyle(.gray).font(.caption2)
                Text("Ollama stopped").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Start") { manager.start() }.font(.caption)
            case .starting:
                ProgressView().controlSize(.mini)
                Text("Starting engine...").font(.caption).foregroundStyle(.secondary)
                Spacer()
            case .running:
                Image(systemName: "circle.fill").foregroundStyle(.green).font(.caption2)
                Text("Engine running").font(.caption).foregroundStyle(.secondary)
                Spacer()
            case .error(let msg):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow).font(.caption2)
                Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Retry") { manager.start() }.font(.caption)
            }
        }
        .padding(8)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Coaching Style Section

/// Sidebar entry for the rubric: which coaching style is active, and the
/// door into the builder.
struct CoachingStyleSection: View {
    @Bindable var settings: SettingsViewModel
    @Bindable var ollamaManager: OllamaManager
    @State private var showBuilder = false

    private var activeName: String {
        ((try? settings.loadRubricOrDefault()) ?? .builtInDefault).name
    }

    var body: some View {
        HStack(spacing: 6) {
            Label("Coaching Style", systemImage: "slider.horizontal.3")
                .font(.headline)
            Spacer()
            Text(activeName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Customize…") {
                showBuilder = true
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
        .sheet(isPresented: $showBuilder) {
            RubricBuilderView(settings: settings, ollamaManager: ollamaManager)
        }
    }
}

// MARK: - Transcript Section

struct TranscriptSection: View {
    @Bindable var simulation: SimulationViewModel
    var isDragOverEntireView: Bool = false
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            sectionContent
                .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Label("Transcript", systemImage: "doc.text")
                    .font(.headline)
                if simulation.transcriptFileName != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        // Dragging a file over the sidebar reveals the drop zone
        .onChange(of: isDragOverEntireView) { _, over in
            if over { isExpanded = true }
        }
    }

    private var sectionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = simulation.transcriptFileName {
                // Loaded state
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text(name).font(.caption).lineLimit(1)
                        Text("\(simulation.utterances.count) utterances, \(simulation.meetingDuration)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        openFile()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Load a different transcript")
                }
            } else {
                // Empty state — drop zone (drop handled by parent SidebarView)
                VStack(spacing: 8) {
                    Image(systemName: isDragOverEntireView ? "arrow.down.doc.fill" : "arrow.down.doc")
                        .font(.system(size: 28))
                        .foregroundStyle(isDragOverEntireView ? .blue : .secondary)
                    Text(isDragOverEntireView ? "Drop to load" : "Drop a transcript here")
                        .font(.callout.bold())
                        .foregroundStyle(isDragOverEntireView ? .primary : .secondary)
                    Text(".txt or .md from Zoom")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .foregroundStyle(isDragOverEntireView ? .blue : Color.secondary.opacity(0.3))
                )
                .background(isDragOverEntireView ? Color.blue.opacity(0.05) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Button("or choose a file...") {
                    openFile()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }

            if let error = simulation.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text,
            .init(filenameExtension: "md")!,
            .init(filenameExtension: "txt")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            simulation.loadTranscript(from: url)
        }
    }
}

// MARK: - Model Section

struct ModelSection: View {
    @Bindable var settings: SettingsViewModel

    private var hasModels: Bool { !settings.availableModels.isEmpty }

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasModels {
                DisclosureGroup(isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $settings.selectedModel) {
                            ForEach(settings.availableModels) { model in
                                HStack {
                                    Text(model.name)
                                    Spacer()
                                    Text(model.parameterSize.isEmpty ? model.sizeLabel : model.parameterSize)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(model.name)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: settings.selectedModel) { _, _ in
                            settings.save()
                        }

                        Toggle("Use mock (no model)", isOn: $settings.useMock)
                            .font(.caption)

                        Button("Browse all models...") {
                            settings.showModelCatalog = true
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 6) {
                        Label("Model", systemImage: "cpu")
                            .font(.headline)
                        Spacer()
                        // Collapsed state still answers "which model?"
                        Text(settings.useMock ? "mock" : settings.selectedModel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else if settings.downloadingModel != nil {
                // Downloading state (shown below)
            } else if !settings.hasCheckedModels {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking models...").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 10) {
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 28))
                            .foregroundStyle(.green)
                        Text("Instant coaching is already on")
                            .font(.callout.bold())
                        Text("Add a local model for smarter AI nudges and reviews — optional. Models run 100% on your Mac; nothing leaves this computer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

                    if let recommended = modelCatalog.first {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                Text("Recommended")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.blue)
                                Spacer()
                                Text(recommended.diskSize)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(recommended.fullName)
                                .font(.body.bold())
                            Text(recommended.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button {
                                settings.downloadModel(recommended)
                            } label: {
                                Label("Download \(recommended.parameterSize) Model", systemImage: "arrow.down.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(10)
                        .background(Color.blue.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.blue.opacity(0.15), lineWidth: 1)
                        )
                    }

                    Button {
                        settings.showModelCatalog = true
                    } label: {
                        Text("Browse all models")
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)

                    Toggle("Use mock (no model needed)", isOn: $settings.useMock)
                        .font(.caption)
                }
            }

            // Download progress
            if let downloading = settings.downloadingModel {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(downloading).font(.caption).bold().lineLimit(1)
                    }
                    ProgressView(value: settings.downloadProgress)
                        .tint(.blue)
                    HStack {
                        Text(settings.downloadStatus)
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f%%", settings.downloadProgress * 100))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Button("Cancel") {
                            settings.cancelDownload()
                        }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                }
                .padding(10)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let error = settings.downloadError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $settings.showModelCatalog) {
            ModelCatalogView(settings: settings)
        }
    }
}

// MARK: - Model Catalog Sheet

struct ModelCatalogView: View {
    @Bindable var settings: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Download Models").font(.title2.bold())
                    Text("Choose a model to run locally via Ollama")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if !settings.availableModels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Installed").font(.caption.bold()).foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    ForEach(settings.availableModels) { model in
                        InstalledModelRow(model: model, settings: settings)
                    }
                }
            }

            Divider().padding(.vertical, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Available to Download").font(.caption.bold()).foregroundStyle(.secondary)
                        .padding(.horizontal)

                    ForEach(modelCatalog) { model in
                        CatalogModelRow(model: model, settings: settings)
                    }
                }
                .padding(.bottom)
            }

            if let downloading = settings.downloadingModel {
                Divider()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Downloading \(downloading)").font(.caption).lineLimit(1)
                        ProgressView(value: settings.downloadProgress)
                    }
                    Text(settings.downloadStatus).font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .trailing)
                    Button("Cancel") { settings.cancelDownload() }
                        .font(.caption2).buttonStyle(.plain).foregroundStyle(.red)
                }
                .padding()
            }
        }
        .frame(width: 520, height: 500)
    }
}

struct InstalledModelRow: View {
    let model: OllamaModel
    @Bindable var settings: SettingsViewModel

    var isSelected: Bool { settings.selectedModel == model.name }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name).font(.body.bold()).lineLimit(1)
                    if isSelected {
                        Text("active")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 8) {
                    if !model.parameterSize.isEmpty {
                        Text(model.parameterSize).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(model.sizeLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isSelected {
                Button("Use") {
                    settings.selectedModel = model.name
                    settings.save()
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
            Button {
                Task { await settings.deleteModel(model.name) }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.7))
            }
            .font(.caption)
            .buttonStyle(.plain)
            .help("Delete model")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.05) : .clear)
    }
}

struct CatalogModelRow: View {
    let model: CatalogModel
    @Bindable var settings: SettingsViewModel

    var isInstalled: Bool { settings.isInstalled(model) }
    var isDownloading: Bool { settings.downloadingModel == model.fullName }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.fullName).font(.body.bold()).lineLimit(1)
                Text(model.description)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    Text(model.parameterSize).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                    Text(model.diskSize).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if isInstalled {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Already installed")
            } else if isDownloading {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    settings.downloadModel(model)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .disabled(settings.downloadingModel != nil)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Live Section

struct LiveSection: View {
    @Bindable var liveSession: LiveSessionViewModel
    @Bindable var settings: SettingsViewModel
    var onToggleOverlay: () -> Void
    @Bindable var ollamaManager: OllamaManager

    /// The semantic coach needs a reachable local model (or mock mode).
    private var aiNudgesUnavailable: Bool {
        !settings.useMock && settings.hasCheckedModels && settings.availableModels.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if liveSession.isLive {
                // Active session
                HStack(spacing: 8) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text(liveSession.isDemo ? "Demo" : "Live")
                        .font(.caption.bold()).foregroundStyle(.green)
                    Spacer()
                    Text(liveSession.elapsedFormatted)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // Status
                if !liveSession.status.isEmpty {
                    Text(liveSession.status)
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                // Stats — one line; the transcript panel already shows what's heard
                Text("\(liveSession.utterances.count) heard · \(liveSession.nudges.count) nudges")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if liveSession.showSilenceWarning {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.slash.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Meeting ended?")
                                .font(.caption.bold())
                            Text("No speech detected for 3+ minutes")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            liveSession.dismissSilenceWarning()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack {
                    Button {
                        liveSession.stopLive()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button {
                        onToggleOverlay()
                    } label: {
                        Image(systemName: "rectangle.inset.filled.on.rectangle")
                    }
                    .buttonStyle(.bordered)
                    .help("Toggle floating overlay")
                }
            } else {
                Button {
                    liveSession.showPreCallForm = true
                } label: {
                    Label("Go Live", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .help("Listens to your meeting audio and coaches you in real time. Instant nudges (talk time, interruptions, unanswered questions) are always on.")
                .sheet(isPresented: $liveSession.showPreCallForm) {
                    PreCallFormView(context: $liveSession.preCallContext) {
                        liveSession.startLive(
                            context: liveSession.preCallContext,
                            settings: settings,
                            ollamaManager: ollamaManager
                        )
                    }
                }

                Toggle("AI nudges", isOn: $settings.semanticCoachEnabled)
                    .font(.caption)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(aiNudgesUnavailable)
                    .help("AI re-reads the conversation each minute for subtle moments — undecided topics, soft commitments. Uses more battery.")
                if aiNudgesUnavailable {
                    Text("Needs a local model — instant nudges still work without one.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Button {
                    liveSession.startDemo()
                } label: {
                    Label("Watch demo", systemImage: "play.rectangle")
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help("Replay a sample meeting to see the coaching in action — no mic, no setup")
            }

            // Post-session: save/delete + review
            if !liveSession.isLive && liveSession.hasSession {
                Divider()

                if liveSession.showPostSession {
                    VStack(alignment: .leading, spacing: 8) {
                        if let path = liveSession.savedPath {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("Saved").font(.caption.bold())
                            }
                            Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }

                        HStack(spacing: 8) {
                            Button {
                                liveSession.dismissPostSession()
                            } label: {
                                Label("Keep", systemImage: "checkmark")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                liveSession.deleteSession()
                            } label: {
                                Label("Delete", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    }
                }

                if liveSession.isGeneratingSummary {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Generating review...").font(.caption).foregroundStyle(.secondary)
                    }
                } else if !liveSession.showPostSession {
                    Button {
                        liveSession.generateReview(ollamaManager: ollamaManager, settings: settings)
                    } label: {
                        Label("Generate Review", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let error = liveSession.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Feedback Section

struct FeedbackSection: View {
    @Bindable var simulation: SimulationViewModel
    @Bindable var liveSession: LiveSessionViewModel

    private var activeUtterances: [Utterance] {
        if liveSession.hasSession {
            return liveSession.utterances
        }
        return simulation.utterances
    }

    private var sourceLabel: String {
        if liveSession.hasSession {
            return "live session"
        }
        if let name = simulation.transcriptFileName {
            return name
        }
        return "transcript"
    }

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            sectionContent
                .padding(.top, 8)
        } label: {
            Label("Coaching Notes", systemImage: "text.badge.checkmark")
                .font(.headline)
                .help("Paste coaching feedback to improve future detection")
        }
    }

    private var sectionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste coaching feedback to improve future detection")
                .font(.caption).foregroundStyle(.secondary)

            if !activeUtterances.isEmpty {
                Text("Will pair with: \(sourceLabel)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            TextEditor(text: $simulation.feedbackText)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 80, maxHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2))
                )

            HStack {
                Button {
                    saveTraining()
                } label: {
                    Label("Save as Training", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(simulation.feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || activeUtterances.isEmpty)

                if simulation.feedbackSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Spacer()

                let count = TrainingStore.load().count
                if count > 0 {
                    Text("\(count) example\(count == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func saveTraining() {
        let text = simulation.feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !activeUtterances.isEmpty else { return }

        let excerpt = activeUtterances.prefix(80)
            .map { "[\($0.formattedTime)] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")

        let signals = TrainingStore.parseFeedback(text)

        let example = TrainingExample(
            date: Date(),
            transcriptExcerpt: String(excerpt.prefix(3000)),
            feedback: text,
            signals: signals
        )

        TrainingStore.append(example)
        simulation.feedbackSaved = true
        mclog("[Training] Saved example with \(signals.count) parsed signals, source=\(sourceLabel)")
    }
}

// MARK: - Welcome Sheet

/// First-launch welcome: one paragraph of what the app is, and the demo as
/// the default action — the aha moment should come before any setup.
struct WelcomeSheet: View {
    var onDemo: () -> Void
    var onSkip: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Welcome to Meeting Coach")
                .font(.title2.bold())
            Text("It listens to your meetings and nudges you in the moment — talk less, land your point, lock decisions. Everything runs on your Mac; audio never leaves it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            HStack(spacing: 12) {
                Button("Skip") { onSkip() }
                Button {
                    onDemo()
                } label: {
                    Label("Watch a 30-second demo", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 480)
    }
}

// MARK: - Helpers

private func speakerColor(_ speaker: String) -> Color {
    let lower = speaker.trimmingCharacters(in: .whitespaces).lowercased()
    if ["you", "me", "self", "noah kagan"].contains(lower) { return .blue }
    if lower == "meeting" { return .secondary }
    // Diarized speakers: stable distinct color per index.
    if lower.hasPrefix("speaker "), let n = Int(lower.dropFirst("speaker ".count)) {
        let palette: [Color] = [.blue, .orange, .purple, .teal, .pink, .indigo, .brown, .mint]
        return palette[(n - 1 + palette.count) % palette.count]
    }
    return .orange
}

private func splitWords(_ text: String, perChunk: Int = 8) -> [String] {
    let words = text.split(separator: " ")
    guard words.count >= perChunk else { return [text] }
    var chunks: [String] = []
    var i = 0
    while i < words.count {
        let end = min(i + perChunk, words.count)
        chunks.append(words[i..<end].joined(separator: " "))
        i = end
    }
    return chunks
}
