import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var ollamaManager: OllamaManager
    // Owned by the App so the menu bar scene drives the same session.
    @Bindable var liveSession: LiveSessionViewModel
    @Bindable var settings: SettingsViewModel
    @State private var simulation = SimulationViewModel()
    @State private var overlayPanel: CoachingOverlayPanel?
    /// The user closed the overlay this session — nudges stop re-asserting
    /// it until the next session starts.
    @State private var overlayDismissed = false
    @AppStorage("hasSeenDemo") private var hasSeenDemo = false
    @State private var showWelcome = false
    @State private var showGiveSheet = false
    @State private var searchQuery = ""
    /// Session open in the main pane; nil = whatever else is active.
    @State private var selectedSessionURL: URL?

    private var activeSearch: String {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        return q.count >= 2 ? q : ""
    }

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            // Custom 46px title bar (window uses .hiddenTitleBar; the
            // native traffic lights overlay the left edge).
            HStack {
                Spacer()
                Text("Meeting Coach")
                    .font(Dorado.barlowBold(14))
                    .foregroundStyle(Dorado.grey500)
                Spacer()
            }
            .overlay(alignment: .trailing) {
                Button { openSettings() } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Dorado.grey500)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // No focus ring: as the window's first focusable control it
                // drew a blue box on launch.
                .focusEffectDisabled()
                .padding(.trailing, 16)
                .help("Settings")
            }
            .frame(height: 46)
            .background(Color.white)

            // Noah's call (2026-08-04): Dorado paint, 0.12.0 bones — the
            // pre-redesign sidebar and main-pane flow stay exactly as they
            // were; only colors/type/buttons carry the design language.
            HSplitView {
                VStack(spacing: 0) {
                    SidebarView(simulation: simulation, settings: settings,
                                liveSession: liveSession, ollamaManager: ollamaManager,
                                searchQuery: $searchQuery,
                                selectedSession: $selectedSessionURL,
                                onToggleOverlay: toggleOverlay)
                }
                .frame(minWidth: 280, idealWidth: 300, maxWidth: 340)
                .background(Color.white)

                // Main content — an opened session wins (closing returns
                // you), then search (clearing the box returns you), then
                // live session, loaded transcript, or progress
                if let sessionURL = selectedSessionURL {
                    SessionDetailView(url: sessionURL, highlightQuery: activeSearch) {
                        selectedSessionURL = nil
                    }
                    .frame(minWidth: 400)
                } else if !activeSearch.isEmpty {
                    SearchResultsView(query: activeSearch) { url in
                        selectedSessionURL = url
                    }
                    .frame(minWidth: 400)
                } else if liveSession.isLive || liveSession.hasSession {
                    LiveTimelineView(liveSession: liveSession)
                        .frame(minWidth: 400)
                } else if simulation.transcriptFileName != nil {
                    SimulationTimelineView(simulation: simulation)
                        .frame(minWidth: 400)
                } else {
                    ProgressDashboardView(liveSession: liveSession, settings: settings)
                        .frame(minWidth: 400)
                }
            }
        }
        // The hidden title bar still reserves top safe-area; without this
        // the traffic lights sat in an empty strip ABOVE the custom 46px
        // bar (double-height header, Noah 2026-08-04). Ignoring it lets
        // the bar own the top edge with the lights overlaying its left.
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.light)   // the Dorado palette is light-only
        .task {
            // No longer wait for Ollama before allowing app use.
            // Refresh models in background for when post-call review is needed.
            settings.ollamaManager = ollamaManager
            // Fetch the transcription model off the critical path so the
            // first real session starts on Parakeet instead of the fallback.
            // (Also kicked off from the menu bar label for windowless
            // launches — startIfNeeded coalesces the two.)
            ParakeetDownloadState.shared.startIfNeeded()
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
            // A new session gets a fresh overlay — a close only ever means
            // "not this meeting".
            if isLive { overlayDismissed = false; showOverlay() } else { hideOverlay() }
        }
        .onChange(of: settings.showCoachOverlay) { _, on in
            if !on { hideOverlay() } else if liveSession.isLive { showOverlay() }
        }
        // The viral-loop trigger moment: the user's SECOND real coached
        // meeting just ended — they've seen the value twice, and the ask
        // no longer lands mid-first-impression. Once ever; demo replays
        // never set showPostSession so they can't trigger it. (The flag
        // key still says "first session" — it also grandfathers everyone
        // who already saw the prompt under the old first-meeting rule.)
        .onChange(of: liveSession.showPostSession) { _, shown in
            guard shown,
                  !ReferralInvites.firstSessionPromptShown,
                  ReferralInvites.completedMeetingCount >= 2 else { return }
            ReferralInvites.firstSessionPromptShown = true
            showGiveSheet = true
        }
        .sheet(isPresented: $showGiveSheet) {
            GiveMeetingCoachView(asSheet: true)
        }
        // Typing a new search closes an open session so results show.
        .onChange(of: searchQuery) { _, _ in
            selectedSessionURL = nil
        }
        .onChange(of: liveSession.activeNudge?.id) { _, id in
            // Re-assert the overlay whenever a nudge fires — but never
            // against an explicit close: Noah closed it repeatedly and it
            // kept coming back. Close now holds for the rest of the
            // session; nudges still land in the coach rail.
            if id != nil, liveSession.isLive, !overlayDismissed { showOverlay() }
        }
        .onAppear {
            // The window can open into an already-live session (started from
            // the menu bar with no window) — onChange never fires for that.
            if liveSession.isLive { showOverlay() }
        }
    }

    private func toggleOverlay() {
        if overlayPanel?.isVisible == true {
            overlayDismissed = true
            hideOverlay()
        } else {
            overlayDismissed = false
            showOverlay()
        }
    }

    private func showOverlay() {
        guard settings.showCoachOverlay else { return }
        if overlayPanel == nil {
            overlayPanel = CoachingOverlayPanel()
        }
        guard let panel = overlayPanel else { return }
        // Install content BEFORE ordering front (NSPanel ships a placeholder
        // contentView, so assign unconditionally). The view observes the
        // session (@Observable), so one hosting view tracks nudges and the
        // talk meter for the whole session without being rebuilt.
        if !(panel.contentView is NSHostingView<CoachingOverlayView>) {
            let view = CoachingOverlayView(liveSession: liveSession, settings: settings) { [weak panel] in
                // Close = gone for the rest of this session (the per-nudge
                // re-show checks the flag); a new session resets it.
                overlayDismissed = true
                panel?.orderOut(nil)
            }
            panel.contentView = NSHostingView(rootView: view)
        }
        // Follow the user's attention: position on the screen holding the
        // frontmost app's window (the call) — unless the user has dragged
        // the panel somewhere, which wins permanently.
        panel.repositionToActiveScreen()
        panel.orderFront(nil)
    }

    private func hideOverlay() {
        overlayPanel?.orderOut(nil)
    }
}

// MARK: - Live Timeline View

struct LiveTimelineView: View {
    @Bindable var liveSession: LiveSessionViewModel

    var body: some View {
        HSplitView {
            // Left, dominant: the live transcript — the product.
            transcriptPanel
                .frame(minWidth: 380)

            // Right: the coach rail. Quiet by design — a few high-bar
            // nudges, not a feed to monitor. Freely resizable: the old
            // 340pt cap made the split divider stop dead while the review
            // card stayed cramped. The 280 floor is the nudge card's real
            // minimum (timestamp gutter + fixed-size badge) — any narrower
            // and the whole rail's content overflows and clips.
            nudgesPanel
                .frame(minWidth: 280, idealWidth: 300, maxWidth: 560)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MCTheme.canvas)
    }

    private var nudgesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("COACH")
                    .font(.caption.weight(.semibold))
                    .kerning(1.0)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !liveSession.nudges.isEmpty {
                    Text("\(liveSession.nudges.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 2)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        // A review built from a fallback-engine transcript
                        // inherits its gaps — say so before anyone reads
                        // "disjointed conversation" as a verdict on their
                        // meeting instead of on the transcription.
                        if !liveSession.isLive && liveSession.usedFallbackEngine {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "arrow.down.circle")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("This session used the basic transcription engine — the transcript (and this review) missed words. The high-accuracy engine will be ready for your next session.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    ParakeetProgressLine()
                                }
                            }
                            .padding(8)
                            .background(Color.blue.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        // Review card
                        if let review = liveSession.meetingReview {
                            MeetingReviewView(review: review, recapText: recapText(review)) { id in
                                liveSession.toggleActionItem(id)
                            }
                            .id("summary")
                            Divider().padding(.vertical, 4)
                        } else if liveSession.isGeneratingSummary {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Generating review...").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 4).id("summary-loading")
                        }

                        // Nudge feed — the empty state says the quiet part:
                        // silence is the default, not a malfunction.
                        if liveSession.nudges.isEmpty {
                            VStack(spacing: 8) {
                                if liveSession.isLive {
                                    Image(systemName: "waveform.badge.mic")
                                        .font(.system(size: 28))
                                        .foregroundStyle(.green.opacity(0.4))
                                        .symbolEffect(.pulse)
                                    Text("Quiet unless something's\nworth saying")
                                        .font(.caption).foregroundStyle(.tertiary)
                                        .multilineTextAlignment(.center)
                                } else if liveSession.hasSession {
                                    Text("Session ended").font(.caption).foregroundStyle(.tertiary)
                                } else {
                                    Text("Nudges appear here —\nonly the ones that matter")
                                        .font(.caption).foregroundStyle(.tertiary)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        }

                        ForEach(liveSession.nudges) { nudge in
                            NudgeCardView(nudge: nudge,
                                          quoteTurns: nudge.type.showsQuote
                                              ? liveSession.turnsAround(nudge.quoteTimestamp ?? nudge.timestamp)
                                              : []) { feedback in
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
        .background(MCTheme.canvas)
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Slim utility row — no pane title, the transcript IS the pane.
            if !liveSession.isLive && liveSession.hasSession && !liveSession.turns.isEmpty {
                HStack {
                    Spacer()
                    TranscriptHeaderStats(liveSession: liveSession)
                    CopyButton(help: "Copy transcript") { transcriptText() }

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

            // Degraded capture is easy to miss in the status caption — make
            // it loud: no You/Them separation until Screen Recording is on.
            if liveSession.isLive && liveSession.micOnly {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Only hearing your mic — not the meeting")
                            .font(.caption.bold())
                        Text("MeetingCoach can't hear the other participants, so it can't tell who's speaking. Grant Screen Recording, then restart the session.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Fallback engine: fragmented transcripts are EXPECTED here —
            // without this banner users read them as broken settings. The
            // one-line status that said so vanishes under the first nudge.
            if liveSession.isLive && liveSession.usedFallbackEngine {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transcript accuracy is reduced this session")
                            .font(.caption.bold())
                        Text("The high-accuracy engine wasn't ready when this session started. Expect missing words today — your next session will be much better.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ParakeetProgressLine()
                    }
                    Spacer()
                }
                .padding(8)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Ambient strip: elapsed + talk split as calm, always-on info —
            // never a judgment (no warning colors here; the overlay keeps
            // its own cue). Isolated in a child view so per-second clock
            // ticks and talkStats mutations re-render only this strip.
            AmbientStatsStrip(liveSession: liveSession)

            // Pre-loaded questions as a live checklist, ticking off as the
            // transcript covers them.
            if liveSession.isLive && !liveSession.preCallContext.plannedQuestions.isEmpty {
                PlannedQuestionsCard(liveSession: liveSession)
            }

            LiveTranscriptPane(liveSession: liveSession)
        }
        .padding(12)
        .background(MCTheme.canvas)
    }

    private func recapText(_ review: MeetingReview) -> String {
        RecapExporter.markdown(
            summary: review.recapMarkdown,
            context: liveSession.preCallContext,
            durationMinutes: max(1, Int(liveSession.elapsedTime) / 60),
            talkShare: liveSession.talkStats.sessionShare
        )
    }

    // Per-utterance blocks with real time-of-day ranges — reads like a
    // Zoom transcript, not a wall of coalesced turns. Shared by the copy
    // and download buttons so the two can never drift apart.
    private func transcriptText() -> String {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        let start = liveSession.sessionStartDate
        func stamp(_ offset: TimeInterval) -> String {
            if let start {
                return clock.string(from: start.addingTimeInterval(offset))
            }
            let s = Int(offset)
            return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return liveSession.utterances
            .map { u in
                "\(stamp(u.t)) --> \(stamp(max(u.endT, u.t + 1)))\n\(u.speaker): \(u.text)"
            }
            .joined(separator: "\n\n")
    }

    private func exportTranscript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        panel.nameFieldStringValue = "transcript_\(formatter.string(from: Date())).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? transcriptText().write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Ambient stats for the transcript panel: elapsed time and the You/Them
/// talk split, always visible during a session with no setup. Deliberately
/// neutral — this is information, not coaching; the talkTime nudge and the
/// floating overlay own the judgment. Reads talkStats itself so its
/// ~per-second updates don't re-render the parent panel.
private struct AmbientStatsStrip: View {
    var liveSession: LiveSessionViewModel

    var body: some View {
        if liveSession.isLive || liveSession.hasSession {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(liveSession.elapsedFormatted)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Text(liveSession.isLive ? "ELAPSED" : "DURATION")
                        .font(.caption2).kerning(0.8).foregroundStyle(.tertiary)
                }

                if let share = liveSession.talkStats.recentShare ?? liveSession.talkStats.sessionShare {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("You ").font(.caption2.weight(.semibold)).foregroundStyle(Color.blue)
                            + Text("\(Int(share * 100))%").font(.caption2.monospacedDigit().weight(.semibold))
                            Spacer()
                            Text("Them ").font(.caption2.weight(.semibold)).foregroundStyle(Color.purple)
                            + Text("\(100 - Int(share * 100))%").font(.caption2.monospacedDigit().weight(.semibold))
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.purple.opacity(0.3))
                                Capsule()
                                    .fill(Color.blue.opacity(0.65))
                                    .frame(width: max(3, geo.size.width * share))
                            }
                        }
                        .frame(height: 5)
                        .animation(.easeOut(duration: 0.4), value: share)
                    }
                } else if liveSession.isLive {
                    Text("listening…")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                } else {
                    Spacer()
                }

                if liveSession.isLive {
                    HStack(spacing: 5) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("Listening")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.green.opacity(0.12)))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .cardStyle()
        }
    }
}

/// Live checklist of the questions entered in pre-call setup. Coverage is
/// detected from the transcript, and rows are tappable — a tap overrides
/// the detection in either direction.
private struct PlannedQuestionsCard: View {
    var liveSession: LiveSessionViewModel
    @State private var collapsed = false

    var body: some View {
        let questions = liveSession.preCallContext.plannedQuestions
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("QUESTIONS TO ASK")
                    .font(.caption2.weight(.semibold))
                    .kerning(1.0)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(liveSession.askedPlannedQuestions.count)/\(questions.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() }
                } label: {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
            if !collapsed {
                ForEach(Array(questions.enumerated()), id: \.offset) { i, question in
                    let asked = liveSession.askedPlannedQuestions.contains(i)
                    Button {
                        liveSession.togglePlannedQuestion(i)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: asked ? "checkmark.circle.fill" : "circle")
                                .font(.caption)
                                .foregroundStyle(asked ? Color.green : Color.secondary)
                            Text(question)
                                .font(.caption)
                                .strikethrough(asked)
                                .foregroundStyle(asked ? Color.secondary : Color.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(asked ? "Mark as not asked" : "Mark as asked")
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .cardStyle()
    }
}

/// Isolated so per-utterance updates only re-render this Text, not the
/// whole transcript panel. Elapsed time lives in the ambient strip now.
private struct TranscriptHeaderStats: View {
    var liveSession: LiveSessionViewModel

    var body: some View {
        Text("\(liveSession.utterances.count) lines")
            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
    }
}

/// Renders the pre-built turns from the view model — no per-frame re-joining,
/// stable identity per turn.
/// One committed turn in the live transcript. Extracted into its own view
/// so SwiftUI's struct diffing skips unchanged rows: the paragraph split
/// (an O(text) sentence/word pass) re-runs only for the turn whose text is
/// still coalescing — not for every turn on every utterance, which made the
/// pane O(session²) over an hour-long call.
private struct TranscriptTurnRow: View, Equatable {
    /// Rows re-render only when the turn's CONTENT changed — the stored
    /// closures defeat SwiftUI's automatic struct diffing, so without this
    /// every partial tick re-evaluated (and re-laid-out) every row, which
    /// made long transcripts feel sluggish once words became link runs.
    /// Paired with .equatable() at the use site. `nonisolated` because
    /// Equatable's requirement lives outside the view's main-actor
    /// isolation — which also means it may only touch Sendable lets, so
    /// it compares the turn and deliberately ignores the closures (the
    /// pane always passes the same handlers).
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.turn.id == rhs.turn.id
            && lhs.turn.text == rhs.turn.text
            && lhs.turn.speaker == rhs.turn.speaker
    }

    let turn: Turn
    /// Present = this speaker can be given a real name (click the label).
    var onRename: ((String, String) -> Void)?
    /// Present = words are click-to-fix (wrote, shouldBe): clicking a
    /// misheard word opens the fix popover with it pre-filled; right-click
    /// covers multi-word phrases. Fixes land in the vocabulary and rewrite
    /// the transcript in place — corrections happen where the mistake is
    /// seen, not in a settings field.
    var onFixTerm: ((String, String) -> Void)?

    @State private var showRenamePopover = false
    @State private var nameField = ""
    @State private var showFixPopover = false
    @State private var fixWrote = ""
    @State private var fixShouldBe = ""
    @FocusState private var focusShouldBe: Bool

    private var renameable: Bool { onRename != nil && !turn.isYou }

    var body: some View {
        // Columnar: speaker | time | text — reads like a chat log, scans by
        // color down the speaker gutter.
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(turn.speaker)
                .font(.caption.bold())
                .foregroundStyle(speakerColor(turn.speaker))
                .frame(minWidth: 42, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard renameable else { return }
                    nameField = ""
                    showRenamePopover = true
                }
                .help(renameable ? "Click to name this speaker" : "")
                .popover(isPresented: $showRenamePopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Who is \(turn.speaker)?")
                            .font(.caption.bold())
                        TextField("Name", text: $nameField)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .onSubmit { submitRename() }
                        Text("Their voice is saved locally so future meetings label them automatically.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 160)
                        Button("Save") { submitRename() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(nameField.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(12)
                }
            Text(turn.formattedTime)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .leading)
            // Long unattributed turns (mic-only mode) read as a wall —
            // break into paragraphs for display only; signal analysis
            // still sees one turn.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(paragraphs(turn.text).enumerated()), id: \.offset) { _, para in
                    Text(onFixTerm != nil ? Self.clickableWords(para) : AttributedString(para))
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Every word carries an invisible mcfix:// link (see
            // clickableWords) — clicking a misheard word opens the fix
            // popover with that word pre-filled, so the user only types
            // what it SHOULD be.
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "mcfix" else { return .systemAction }
                fixWrote = url.lastPathComponent
                fixShouldBe = ""
                showFixPopover = true
                return .handled
            })
            .contextMenu {
                if onFixTerm != nil {
                    // Multi-word garbles ("tidy khac viet") — start blank
                    // and type the phrase.
                    Button("Fix a misheard phrase…") {
                        fixWrote = ""
                        fixShouldBe = ""
                        showFixPopover = true
                    }
                }
            }
            .popover(isPresented: $showFixPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(fixWrote.isEmpty ? "Fix a misheard phrase"
                                          : "Fix \u{201C}\(fixWrote)\u{201D}")
                        .font(.caption.bold())
                        .lineLimit(1)
                        .frame(maxWidth: 190, alignment: .leading)
                    TextField("It wrote…", text: $fixWrote)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                    TextField("It should be…", text: $fixShouldBe)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                        .focused($focusShouldBe)
                        .onSubmit { submitFix() }
                    Text("Fixed in this transcript now, and on every future one. Manage terms in Settings → General → Vocabulary.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 190)
                    Button("Fix it") { submitFix() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(fixWrote.trimmingCharacters(in: .whitespaces).isEmpty
                                  || fixShouldBe.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
                .onAppear {
                    // Word-click pre-fills what was written — the only thing
                    // left to type is the correction.
                    if !fixWrote.isEmpty { focusShouldBe = true }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func submitFix() {
        let wrote = fixWrote.trimmingCharacters(in: .whitespaces)
        let shouldBe = fixShouldBe.trimmingCharacters(in: .whitespaces)
        guard !wrote.isEmpty, !shouldBe.isEmpty else { return }
        showFixPopover = false
        onFixTerm?(wrote, shouldBe)
    }

    /// Built word-link paragraphs, keyed by text. A turn's text is stable
    /// once it stops coalescing, so everything but the actively-growing
    /// turn hits this cache. Main-actor confined (only View bodies touch
    /// it); crudely capped so an hours-long session can't grow it forever.
    @MainActor private static var wordLinkCache: [String: AttributedString] = [:]

    /// The paragraph with every word wrapped in an invisible `mcfix://`
    /// link, styled as plain text. SwiftUI's Text can't report which word
    /// was clicked, but it CAN route link activations — so words become
    /// their own click targets while the row stays one cheap Text view
    /// (no per-word subviews). Separator runs stay UNLINKED: clicking the
    /// gap between words must not pop a fix for the word before it.
    @MainActor
    static func clickableWords(_ para: String) -> AttributedString {
        if let hit = wordLinkCache[para] { return hit }
        var out = AttributedString()
        var word = ""
        var gap = ""
        func flushGap() {
            guard !gap.isEmpty else { return }
            out += AttributedString(gap)
            gap = ""
        }
        func flushWord() {
            guard !word.isEmpty else { return }
            var run = AttributedString(word)
            if let encoded = word.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
               let url = URL(string: "mcfix://w/\(encoded)") {
                run.link = url
                run.foregroundColor = .primary
            }
            out += run
            word = ""
        }
        for ch in para {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "\u{2019}" || ch == "-" {
                flushGap()
                word.append(ch)
            } else {
                flushWord()
                gap.append(ch)
            }
        }
        flushWord()
        flushGap()
        if wordLinkCache.count > 4000 { wordLinkCache.removeAll() }
        wordLinkCache[para] = out
        return out
    }

    private func submitRename() {
        let name = nameField.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        showRenamePopover = false
        onRename?(turn.speaker, name)
    }
}

/// One-tap confirmation for an LLM-inferred speaker name ("Them 1 sounds
/// like Sarah"). Never auto-applied — a wrong name would be saved with the
/// voice and poison future sessions.
private struct NameSuggestionBar: View {
    var liveSession: LiveSessionViewModel

    var body: some View {
        ForEach(liveSession.speakerNameSuggestions) { s in
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
                (Text(s.label).bold() + Text(" sounds like ") + Text(s.name).bold())
                    .font(.caption)
                Spacer(minLength: 4)
                Button {
                    liveSession.confirmNameSuggestion(s)
                } label: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Yes — label \(s.label) as \(s.name)")
                Button {
                    liveSession.dismissNameSuggestion(s)
                } label: {
                    Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("No, dismiss")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))
            .clipShape(Capsule())
        }
    }
}

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
            .cardStyle()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // Plain VStack, NOT LazyVStack: lazy layout caches row
                    // positions, and removing the tall pending row when it
                    // commits leaves phantom blank space mid-list (Parakeet
                    // partials grow into full paragraphs, so the hole is big).
                    VStack(alignment: .leading, spacing: 0) {
                        if !liveSession.speakerNameSuggestions.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                NameSuggestionBar(liveSession: liveSession)
                            }
                            .padding(.horizontal, 14).padding(.top, 10)
                        }
                        ForEach(liveSession.turns) { turn in
                            TranscriptTurnRow(
                                turn: turn,
                                onRename: { label, name in
                                    liveSession.renameSpeaker(label, to: name)
                                },
                                onFixTerm: { wrote, shouldBe in
                                    liveSession.fixMisheardTerm(wrote: wrote, canonical: shouldBe)
                                })
                                .equatable()
                                .padding(.horizontal, 14).padding(.vertical, 9)
                            Divider().opacity(0.35).padding(.leading, 14)
                        }
                        // Live pending line(s): what the recognizer hears right
                        // now, before it's committed as a turn — dictation feel.
                        ForEach(pendingLines, id: \.speaker) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(line.speaker == "Meeting" ? "" : line.speaker)
                                    .font(.caption.bold())
                                    .foregroundStyle(speakerColor(line.speaker).opacity(0.6))
                                    .frame(minWidth: 42, alignment: .leading)
                                Text(line.text)
                                    .font(.callout.italic())
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                        }
                        Color.clear.frame(height: 1).id("transcript-bottom")
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .cardStyle()
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
    /// The transcript moment behind the nudge (trigger turn + reply), when
    /// the session has it — reveals what was actually said on demand.
    var quoteTurns: [Turn] = []
    let onFeedback: (NudgeFeedback) -> Void
    @State private var showQuote = false

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
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 8) {
                    Text(nudge.text)
                        .font(.system(.body, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    // "Wrong" is a dismissal, not a rating — it lives at the
                    // card's corner, away from the thumbs.
                    if nudge.feedback == nil {
                        feedbackButton(.wrong, help: "Wrong call — dismiss", icon: "xmark")
                    }
                }

                HStack(spacing: 8) {
                    // Type label — quiet small caps, no pill chrome. Fixed
                    // so a tight card can never fold it into a letter column.
                    Text(nudge.badgeLabel.uppercased())
                        .font(.caption2.weight(.medium))
                        .kerning(0.6)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()

                    // Window the signal reasons over — "last 5 min" vs "this
                    // meeting" was genuinely ambiguous before.
                    // Unlike the badge, the hint may truncate in a tight
                    // card — a rigid hint widens the card's floor past
                    // what a narrow rail can hold.
                    if let hint = scopeHint {
                        Text("· \(hint)")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if !quoteTurns.isEmpty {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { showQuote.toggle() }
                        } label: {
                            Label(showQuote ? "Hide" : "What was said",
                                  systemImage: "quote.opening")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show the transcript behind this nudge")
                    }

                    // Feedback — thumbs, or the recorded result.
                    if let feedback = nudge.feedback {
                        HStack(spacing: 4) {
                            Image(systemName: feedbackIcon(feedback))
                            Text(feedbackLabel(feedback))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 2) {
                            feedbackButton(.useful, help: "Useful", icon: "hand.thumbsup")
                            feedbackButton(.annoying, help: "Not useful", icon: "hand.thumbsdown")
                        }
                    }
                }

                if showQuote && !quoteTurns.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(quoteTurns) { turn in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(turn.speaker)
                                    .font(.caption2.bold())
                                    .foregroundStyle(speakerColor(turn.speaker))
                                Text(excerpt(turn))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .cardStyle()
    }

    /// Trim long turns to the part near the nudge: the tail of the turn
    /// that triggered it, the head of the reply.
    private func excerpt(_ turn: Turn) -> String {
        let text = turn.text.trimmingCharacters(in: .whitespaces)
        guard text.count > 220 else { return text }
        if turn.t <= nudge.timestamp && nudge.timestamp <= turn.endT {
            return "…" + String(text.suffix(217))
        }
        return String(text.prefix(217)) + "…"
    }

    /// What window the signal reasons over — nil when "now" is obvious.
    private var scopeHint: String? {
        switch nudge.type {
        case .voiceShare: return "last 5 min"
        case .talkTime: return "current stretch"
        default: return nudge.type.isPositive ? "just now" : nil
        }
    }

    private func feedbackButton(_ feedback: NudgeFeedback, help: String, icon: String) -> some View {
        Button {
            onFeedback(feedback)
        } label: {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func feedbackLabel(_ feedback: NudgeFeedback) -> String {
        switch feedback {
        case .useful: return "Useful"
        case .annoying: return "Not useful"
        case .wrong: return "Wrong"
        }
    }

    private func feedbackIcon(_ feedback: NudgeFeedback) -> String {
        switch feedback {
        case .useful: return "hand.thumbsup.fill"
        case .annoying: return "hand.thumbsdown.fill"
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

/// Small icon button that copies text and flashes a "Copied ✓" confirmation
/// for 2s — shared by the transcript header and the recap card.
struct CopyButton: View {
    let help: String
    let text: () -> String
    @State private var copied = false

    var body: some View {
        if copied {
            Label("Copied", systemImage: "checkmark")
                .font(.caption)
                .foregroundStyle(.green)
        }
        Button {
            RecapExporter.copyToPasteboard(text())
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
        .help(help)
    }
}

struct SidebarView: View {
    @Bindable var simulation: SimulationViewModel
    @Bindable var settings: SettingsViewModel
    @Bindable var liveSession: LiveSessionViewModel
    @Bindable var ollamaManager: OllamaManager
    @Binding var searchQuery: String
    @Binding var selectedSession: URL?
    var onToggleOverlay: () -> Void
    // Open by default (the section shrank in the zero-config pivot); a
    // user's collapse sticks across launches. Sub-sections inside keep
    // their own collapsed-by-default state.
    @AppStorage("sidebarAdvancedExpanded") private var showAdvanced = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Engine auto-starts when Go Live / review needs it,
                    // so only surface transient or error states here
                    switch ollamaManager.status {
                    case .stopped, .running:
                        EmptyView()
                    case .starting, .error:
                        OllamaStatusBar(manager: ollamaManager)
                    }

                    // Live coaching — the main feature. Everything else is
                    // configuration, and configuration lives behind the
                    // Advanced door pinned at the bottom: nobody has to
                    // think before Go Live.
                    LiveSection(liveSession: liveSession,
                                settings: settings,
                                onToggleOverlay: onToggleOverlay,
                                ollamaManager: ollamaManager)
                        .padding(12)
                        .cardStyle()

                    SessionsSection(searchQuery: $searchQuery,
                                selectedSession: $selectedSession,
                                liveSession: liveSession)
                }
                .padding(12)
            }
            .background(MCTheme.canvas)

            Divider()
            DisclosureGroup(isExpanded: $showAdvanced) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        PlannedQuestionsSection()
                        Divider()
                        FeedbackSection(simulation: simulation, liveSession: liveSession,
                                        settings: settings, ollamaManager: ollamaManager)
                        Divider()
                        ModelSection(settings: settings)
                        Text("AI nudges and the meeting summary switch on automatically when a model is installed.")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 10)
                }
                .frame(maxHeight: 320)
            } label: {
                // Whole row toggles, not just the chevron — the label is a
                // full-width tap target.
                HStack {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation { showAdvanced.toggle() }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(MCTheme.canvas)

            Divider()
            // Real bundle version (stamped from the release tag by CI) — never
            // hardcode here again; a stale footer in an auto-updating app is
            // worse than none. Debug builds are marked so a dev copy is never
            // mistaken for the installed release.
            Text(Self.versionLabel)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.quaternary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
    }

    static var versionLabel: String {
        #if DEBUG
        // Dev builds carry a placeholder MARKETING_VERSION (CI stamps the
        // real one only at release), which made every dev build read as
        // ancient. Show the commit instead (stamped by project.yml).
        let sha = Bundle.main.object(forInfoDictionaryKey: "MCBuildCommit") as? String
        return "dev @ \(sha ?? "local") · unreleased"
        #else
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "v\(v)"
        #endif
    }

}

// MARK: - Sessions (search + recent chats)

/// Sidebar card: one search box over every saved chat, plus the most recent
/// sessions a click away. The transcript archive is the product — it should
/// never feel like files in a folder.
private struct SessionsSection: View {
    @Binding var searchQuery: String
    @Binding var selectedSession: URL?
    var liveSession: LiveSessionViewModel
    /// URL + resolved display title (header title falling back to the date)
    /// loaded together so a rename can refresh what's on screen.
    @State private var recent: [(url: URL, title: String)] = []
    @State private var renameTarget: URL?
    @State private var renameText = ""
    /// Collapsed = the 4 most recent; "See all" reveals the full archive
    /// in place (the sidebar already scrolls).
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SESSIONS")
                .font(.caption2.weight(.semibold))
                .kerning(1.0)
                .foregroundStyle(.tertiary)

            TextField("Search chats…", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            if liveSession.isLive {
                HStack {
                    Text("This meeting").font(.caption)
                    Spacer()
                    Text("live").font(.caption2.bold()).foregroundStyle(.green)
                }
            }

            ForEach(showAll ? recent : Array(recent.prefix(4)), id: \.url) { item in
                Button {
                    // Opens in the main pane — the file is one more click
                    // away (context menu) for people who want the editor.
                    selectedSession = item.url
                } label: {
                    HStack {
                        Text(item.title)
                            .font(.caption).foregroundStyle(.primary).lineLimit(1)
                        Spacer()
                        if let date = TranscriptSearch.shortDate(for: item.url) {
                            Text(date)
                                .font(.caption2).foregroundStyle(.tertiary)
                                .fixedSize()
                        }
                        Image(systemName: "arrow.up.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the saved transcript — \(TranscriptSearch.title(for: item.url))")
                .contextMenu {
                    Button("Rename…") {
                        renameText = TranscriptSearch.headerTitle(at: item.url) ?? ""
                        renameTarget = item.url
                    }
                    Button("Open File in Editor") {
                        NSWorkspace.shared.open(item.url)
                    }
                }
            }

            if recent.count > 4 {
                Button {
                    withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15)) {
                        showAll.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(showAll ? "Show recent" : "See all \(recent.count)")
                            .font(Dorado.roboto(12, .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(showAll ? 180 : 0))
                        Spacer()
                    }
                    .foregroundStyle(Dorado.grey500)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }

            if recent.isEmpty && !liveSession.isLive {
                Text("Saved chats appear here.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .cardStyle()
        // Refresh when a session ends and saves.
        .task(id: liveSession.hasSession && !liveSession.isLive) {
            reloadRecent()
        }
        .alert("Name this session", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Person · subject", text: $renameText)
            Button("Save") {
                if let url = renameTarget {
                    TranscriptSearch.setTitle(renameText, for: url)
                    reloadRecent()
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Shown in the sessions list instead of the date. Clear it to go back to the date.")
        }
    }

    private func reloadRecent() {
        // Untitled sessions get a topic-derived title automatically —
        // written into the file so search and the dashboard agree with the
        // sidebar. Rename (context menu) still overrides.
        recent = TranscriptSearch.sessionFiles().map { url in
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                if let header = TranscriptSearch.headerTitle(in: content) {
                    return (url: url, title: header)
                }
                // A bare Title line is the user's cleared-title sentinel —
                // show the date and do NOT re-suggest over it.
                if !TranscriptSearch.hasTitleLine(in: content),
                   let suggested = TranscriptSearch.suggestedTitle(in: content) {
                    TranscriptSearch.setTitle(suggested, for: url)
                    return (url: url, title: suggested)
                }
            }
            return (url: url, title: TranscriptSearch.title(for: url))
        }
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
        .cardStyle(cornerRadius: 8)
    }
}

// MARK: - Coaching Style Section

/// Sidebar entry for the rubric: which coaching style is active, and the
/// door into the builder.
struct CoachingStyleSection: View {
    @Bindable var settings: SettingsViewModel
    @Bindable var ollamaManager: OllamaManager
    @State private var showBuilder = false

    var body: some View {
        HStack(spacing: 6) {
            Label("Coaching Style", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
            Spacer()
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

// MARK: - Questions to Ask (standing checklist)

/// Advanced row: questions for the next call, pasteable one per line. They
/// join the live checklist (with any per-call ones from the goal form),
/// tick off as the transcript covers them, and clear when the call ends.
struct PlannedQuestionsSection: View {
    @AppStorage("plannedQuestionsText") private var questionsText = ""
    @State private var isExpanded = false

    private var count: Int {
        questionsText.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("One per line — paste a whole list. During a call they show as a checklist and tick off as you ask them. The list clears when the call ends, ready for the next meeting's questions.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $questionsText)
                    .font(.caption)
                    .frame(minHeight: 70, maxHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.secondary.opacity(0.2))
                    )
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Label("Questions to Ask", systemImage: "checklist")
                    .font(.subheadline.weight(.semibold))
                HelpDot(text: "Questions to cover on your next call — discovery questions, deal qualifiers, whatever matters. The coach tracks them live, then clears the list when the call ends.")
                if count > 0 {
                    Spacer()
                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Tiny (?) that reveals a one-paragraph explanation on click.
struct HelpDot: View {
    let text: String
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 230, alignment: .leading)
                .padding(12)
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
                    .font(.subheadline.weight(.semibold))
                HelpDot(text: "Drop in a transcript from another tool (Zoom, Meet, Otter) to replay it through the coach and train it on your real meetings. It never leaves your Mac.")
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

                        Toggle("Use sample coach (no download)", isOn: $settings.useMock)
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
                            .font(.subheadline.weight(.semibold))
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
                                Label("Download Model", systemImage: "arrow.down.circle.fill")
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

                    Toggle("Use sample coach (no download)", isOn: $settings.useMock)
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
                .cardStyle(cornerRadius: 8)
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
                // One click, no ritual — starts with the last-used context.
                // The goal/participants form is opt-in below.
                Button {
                    liveSession.startLive(
                        context: liveSession.preCallContext,
                        settings: settings,
                        ollamaManager: ollamaManager
                    )
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 14, weight: .bold))
                        Text("Go live")
                    }
                }
                .buttonStyle(DoradoPillButtonStyle())
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

                // No goal step, no AI-nudges toggle: the app decides. Goal
                // setup lives under Advanced; the semantic coach runs
                // automatically whenever a local model is installed.
                Text("Transcript saves automatically.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
    var settings: SettingsViewModel
    var ollamaManager: OllamaManager
    /// Loaded once on appear (and bumped on save) — TrainingStore.load()
    /// hits disk + JSON-decodes, far too heavy for a view body that
    /// re-renders per utterance during simulation playback.
    @State private var trainingCount = 0

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
    /// Display names of the signal types the last save taught, e.g.
    /// "Talk Time, Pin the Date" — feedback that the paste was understood.
    @State private var savedSignalNames = ""
    /// The distiller's progress/result line — free-form notes that name no
    /// signals go through the local model, and the user should see that the
    /// paste was understood (or that nothing watchable was found).
    @State private var distillStatus: String?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            sectionContent
                .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Label("Coaching Notes", systemImage: "text.badge.checkmark")
                    .font(.subheadline.weight(.semibold))
                HelpDot(text: "Tell the coach what to work on — your own notes, or feedback pasted from another AI tool. Signals you call out get more sensitive; this is how your nudges become yours. Everything stays private on your Mac.")
            }
        }
    }

    private var sectionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What should the coach watch for? Mention signals by name (\u{201C}talk time\u{201D}, \u{201C}stacked questions\u{201D}) and they tune up for you.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                .disabled(simulation.feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if simulation.feedbackSaved {
                    Label(savedSignalNames.isEmpty
                            ? "Saved"
                            : "Saved — tunes \(savedSignalNames)",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Spacer()

                if trainingCount > 0 {
                    Text("\(trainingCount) example\(trainingCount == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            if let distillStatus {
                Label(distillStatus, systemImage: "sparkles")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { trainingCount = TrainingStore.load().count }
    }

    private func saveTraining() {
        // Notes stand on their own — a transcript excerpt is attached when
        // one is around, but "watch my talk time" needs no meeting paired.
        let text = simulation.feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

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
        trainingCount += 1
        simulation.feedbackSaved = true
        savedSignalNames = Array(
            signals.compactMap { TrainingStore.canonicalType(for: $0.signalId)?.displayName }
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .prefix(4)
        ).joined(separator: ", ")
        mclog("[Training] Saved example with \(signals.count) parsed signals, source=\(sourceLabel)")

        distillNote(text: text, exampleId: example.id)
    }

    // MARK: - Note distillation (LLM)

    /// Free-form notes rarely name signals, so the keyword parse alone
    /// leaves most pastes teaching nothing. Run the note through the local
    /// model: built-in matches join the example's signals (the normal
    /// training effect), and genuinely new patterns become addSignal
    /// suggestions the user approves on the Progress dashboard — a note
    /// never changes what the coach watches silently.
    private func distillNote(text: String, exampleId: UUID) {
        guard !settings.useMock else { return }
        if settings.hasCheckedModels && settings.ollamaReachable && settings.availableModels.isEmpty { return }

        distillStatus = "Reading your note with the local coach…"
        if ollamaManager.status == .stopped { ollamaManager.start() }
        let model = settings.selectedModel

        Task { @MainActor in
            if ollamaManager.status != .running {
                for _ in 1...30 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if ollamaManager.status == .running { break }
                    if case .error = ollamaManager.status { break }
                }
            }
            guard ollamaManager.status == .running else { distillStatus = nil; return }
            await settings.refreshModels()
            guard !settings.availableModels.isEmpty else { distillStatus = nil; return }

            do {
                let extraction = try await NoteDistiller.distill(note: text, model: model)
                applyExtraction(extraction, exampleId: exampleId)
            } catch {
                mclog("[Distill] failed: \(error.localizedDescription)")
                distillStatus = nil
            }
        }
    }

    @MainActor
    private func applyExtraction(_ extraction: NoteDistiller.Extraction, exampleId: UUID) {
        // Built-in matches merge into the saved example — from here on they
        // behave exactly like a keyword hit: sensitivity boost at session
        // start plus few-shot evidence for the semantic coach.
        var taughtNames: [String] = []
        if !extraction.builtin.isEmpty {
            var all = TrainingStore.load()
            if let idx = all.firstIndex(where: { $0.id == exampleId }) {
                let old = all[idx]
                let existing = Set(old.signals.map(\.signalId))
                let fresh = extraction.builtin.filter { !existing.contains($0.signalId) }
                if !fresh.isEmpty {
                    all[idx] = TrainingExample(
                        id: old.id, date: old.date,
                        transcriptExcerpt: old.transcriptExcerpt,
                        feedback: old.feedback,
                        signals: old.signals + fresh)
                    TrainingStore.save(all)
                }
            }
            taughtNames = extraction.builtin
                .compactMap { TrainingStore.canonicalType(for: $0.signalId)?.displayName }
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        }

        // New patterns become pending suggestions — same approval rail as
        // the rubric advisor's own proposals.
        let rubric = (try? settings.loadRubricOrDefault()) ?? .builtInDefault
        let existingIds = Set(rubric.signals.map(\.id))
        var stored = RubricAdvisor.loadAll()
        var proposed = 0
        for p in extraction.custom {
            let key = "custom:\(p.id)"
            guard !existingIds.contains(p.id),
                  !stored.contains(where: { $0.signalKey == key && $0.kind == .addSignal })
            else { continue }
            stored.append(RubricSuggestion(
                kind: .addSignal, signalKey: key,
                rationale: p.description,
                evidence: p.evidence.isEmpty ? "From your coaching note." : "From your note: “\(p.evidence)”",
                newSignalDescription: p.description,
                newSignalNudge: p.nudge))
            proposed += 1
        }
        if proposed > 0 { RubricAdvisor.saveAll(stored) }

        var parts: [String] = []
        if !taughtNames.isEmpty { parts.append("tunes \(taughtNames.prefix(3).joined(separator: ", "))") }
        if proposed > 0 { parts.append("\(proposed) new signal\(proposed == 1 ? "" : "s") to approve on the Progress dashboard") }
        distillStatus = parts.isEmpty
            ? "No watchable signals found in this note"
            : "Coach read your note — " + parts.joined(separator: " · ")
        mclog("[Distill] builtin=\(extraction.builtin.count) custom-proposed=\(proposed)")
    }
}

// MARK: - Welcome Sheet

/// First-launch welcome: one paragraph of what the app is, and the demo as
/// the default action — the aha moment should come before any setup.
struct WelcomeSheet: View {
    var onDemo: () -> Void
    var onSkip: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [.green, .green.opacity(0.75)],
                                             startPoint: .top, endPoint: .bottom))
                )
            Text("Welcome to Meeting Coach")
                .font(.title2.bold())
            Text("A live transcript and recap for every meeting — zero setup. The coach stays quiet unless something's genuinely worth saying. Everything runs on your Mac; audio never leaves it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            HStack(spacing: 12) {
                Button("Skip") { onSkip() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button {
                    onDemo()
                } label: {
                    Label("Watch a 15-second demo", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(32)
        .frame(width: 480)
    }
}

// MARK: - Shared design language

/// App-wide surfaces and type. The look is paper-light: a warm off-white
/// canvas with pure-white cards floating on it (dark mode stays on system
/// surfaces). Section titles are serif — calm editorial, not chrome.
enum MCTheme {
    /// Pane background. Dorado repaint (2026-08-04): white-first — the
    /// cream paper era ended with the design handoff. (The app currently
    /// forces light appearance; the dark branch stays for a future
    /// dark-mode pass.)
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .underPageBackgroundColor
            : .white
    })
    /// Card surface (light: white, dark: system control background).
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .controlBackgroundColor
            : .white
    })
    /// Serif pane/section title — the one typographic flourish.
    static let paneTitle = Font.system(.title3, design: .serif).weight(.semibold)
}

/// One card language for the whole app: adaptive surface, continuous
/// corners, hairline border — quiet CleanShot-style polish, no shadows.
struct CardStyle: ViewModifier {
    var cornerRadius: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .background(MCTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle(cornerRadius: CGFloat = 10) -> some View {
        modifier(CardStyle(cornerRadius: cornerRadius))
    }
}

// MARK: - Helpers

private func speakerColor(_ speaker: String) -> Color {
    let lower = speaker.trimmingCharacters(in: .whitespaces).lowercased()
    if ["you", "me", "self", "noah kagan"].contains(lower) { return .blue }
    if lower == "them" { return .purple }
    if lower == "meeting" { return .secondary }
    // Diarized speakers: stable distinct color per slot index.
    let palette: [Color] = [.blue, .orange, .purple, .teal, .pink, .indigo, .brown, .mint]
    for prefix in ["speaker ", "them "] where lower.hasPrefix(prefix) {
        if let n = Int(lower.dropFirst(prefix.count)) {
            return palette[(n - 1 + palette.count) % palette.count]
        }
    }
    // Named speakers: deterministic hash → stable color across sessions.
    // Skips blue (slot 0) — that reads as "You" in the gutter.
    var hash: UInt64 = 5381
    for b in lower.utf8 { hash = hash &* 33 &+ UInt64(b) }
    return palette[1 + Int(hash % UInt64(palette.count - 1))]
}

/// Split a long turn into readable paragraphs at sentence boundaries,
/// roughly `maxWords` each. Short turns come back unchanged.
private func paragraphs(_ text: String, maxWords: Int = 70) -> [String] {
    guard text.split(separator: " ").count > maxWords + maxWords / 2 else { return [text] }
    var sentences: [String] = []
    var current = ""
    for ch in text {
        current.append(ch)
        if ch == "." || ch == "?" || ch == "!" {
            let s = current.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { sentences.append(s) }
            current = ""
        }
    }
    let tail = current.trimmingCharacters(in: .whitespaces)
    if !tail.isEmpty { sentences.append(tail) }

    var paras: [String] = []
    var chunk: [String] = []
    var count = 0
    for sentence in sentences {
        let words = sentence.split(separator: " ").count
        if count > 0, count + words > maxWords {
            paras.append(chunk.joined(separator: " "))
            chunk = []
            count = 0
        }
        chunk.append(sentence)
        count += words
    }
    if !chunk.isEmpty { paras.append(chunk.joined(separator: " ")) }
    return paras.isEmpty ? [text] : paras
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
