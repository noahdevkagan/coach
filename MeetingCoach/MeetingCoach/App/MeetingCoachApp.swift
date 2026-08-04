import SwiftUI
import Combine
import Sparkle
import ServiceManagement

@main
struct MeetingCoachApp: App {
    @State private var ollamaManager = OllamaManager()
    // Session + settings live at app scope so the menu bar scene and the
    // main window drive the same coaching session.
    @State private var liveSession = LiveSessionViewModel()
    @State private var settings = SettingsViewModel()
    @State private var detection = MeetingDetectionService()

    // Sparkle auto-updater. startingUpdater: true schedules the background
    // check (respects SUEnableAutomaticChecks in Info.plist); the standard
    // controller shows the familiar "A new version is available" panel with
    // release notes, Download & Install — no custom UI needed.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    init() {
        // An always-available meeting detector must survive "I quit it
        // once": register as a login item on first launch (release builds
        // only — a dev build at login would fight the installed copy).
        // The menu bar toggle can turn it off; that choice is respected.
        #if !DEBUG
        let key = "didSetupLoginItem"
        if UserDefaults.standard.object(forKey: key) == nil {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        }
        #endif
        #if DEBUG
        // Dock icon gets a "D" badge so a dev build is never mistaken for
        // the installed copy when both are running (menu bar already shows
        // a hammer; the Dock and app switcher need the same tell).
        DispatchQueue.main.async { Self.applyDevDockBadge() }
        #endif
    }

    #if DEBUG
    private static func applyDevDockBadge() {
        guard let base = NSApp.applicationIconImage else { return }
        let badged = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            let d = rect.width * 0.44
            let inset = rect.width * 0.04
            let badgeRect = NSRect(x: rect.maxX - d - inset, y: inset,
                                   width: d, height: d)
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
            let label = NSAttributedString(
                string: "D",
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: d * 0.66),
                    .foregroundColor: NSColor.white,
                ])
            let size = label.size()
            label.draw(at: NSPoint(x: badgeRect.midX - size.width / 2,
                                   y: badgeRect.midY - size.height / 2))
            return true
        }
        NSApp.applicationIconImage = badged
    }
    #endif

    var body: some Scene {
        // Window, not WindowGroup: openWindow(id:) on a WindowGroup mints a
        // fresh window per call (the detection pill + menu bar both open it),
        // while Window raises the one existing instance.
        Window("Meeting Coach", id: "main") {
            ContentView(ollamaManager: ollamaManager,
                        liveSession: liveSession,
                        settings: settings)
            // Ollama is no longer auto-started on launch.
            // It will be started lazily when post-call review is requested
            // or when running the legacy LLM-based simulation.
        }
        .defaultSize(width: 1120, height: 740)
        // Dorado redesign: the content view draws its own 46px title bar
        // (centered app name + gear); hiding the native bar keeps only the
        // traffic lights, which overlay the custom bar's left edge.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        // Menu bar: session status, the auto-detect prompt ("Meeting
        // detected — start coaching?"), and quick start/stop. Detection only
        // ever prompts; capture starts exclusively from an explicit click.
        MenuBarExtra {
            MenuBarView(liveSession: liveSession, settings: settings,
                        ollamaManager: ollamaManager, detection: detection,
                        updater: updaterController.updater)
        } label: {
            // The label view is the app's only always-alive SwiftUI view, so
            // it also owns the floating "Meeting Detected" prompt panel.
            MenuBarLabel(liveSession: liveSession, settings: settings,
                         ollamaManager: ollamaManager, detection: detection)
        }

        // Feedback form, opened from the menu bar dropdown.
        Window("Send Feedback", id: "feedback") {
            FeedbackFormView()
        }
        .windowResizability(.contentSize)

        // Give-to-a-friend invite, opened from the menu bar dropdown (the
        // same view runs as a one-time sheet after the first session).
        Window("Give MeetingCoach", id: "give") {
            GiveMeetingCoachView()
        }
        .windowResizability(.contentSize)

        // Preferences (⌘,): General (transcript folder, detection behavior)
        // and Stats (session trends + learned sensitivity).
        Settings {
            TabView {
                GeneralSettingsView(detection: detection, settings: settings)
                    .tabItem { Label("General", systemImage: "gear") }
                ScrollView {
                    SessionTrendsView()
                        .padding()
                }
                .tabItem { Label("Stats", systemImage: "chart.bar.xaxis") }
            }
            .frame(width: 460, height: 520)
        }
    }

}

// MARK: - Menu bar label + detection prompt

/// The menu bar icon. Lives for the whole app lifetime (unlike the menu
/// content, which only exists while open), so it also drives the floating
/// "Meeting Detected — Start Coaching" pill.
struct MenuBarLabel: View {
    @Bindable var liveSession: LiveSessionViewModel
    @Bindable var settings: SettingsViewModel
    @Bindable var ollamaManager: OllamaManager
    @Bindable var detection: MeetingDetectionService
    @Environment(\.openWindow) private var openWindow
    @State private var promptPanel: MeetingPromptPanel?

    var body: some View {
        Image(systemName: symbol)
            .onAppear {
                detection.bind(liveSession: liveSession)
                // Countdown expiry uses the same start path as the pill's
                // "Start Coaching" button.
                detection.onAutoStart = { startFromDetection() }
                // Real meeting names (window titles seen while live) title
                // the saved session; weak capture — detection outlives any
                // one session but not the app.
                liveSession.meetingTitleProvider = { [weak detection] in
                    detection?.detectedMeetingTitle
                }
                // Downloads start at launch, not first use — this label is
                // the app's only always-alive view, so login/menu-bar-only
                // launches fetch too. Sequential on purpose: Parakeet
                // (~600 MB, the core product) first, then the recommended
                // LLM — parallel multi-GB pulls would just halve each other.
                ParakeetDownloadState.shared.startIfNeeded {
                    Task { await settings.autoDownloadRecommendedIfNeeded() }
                }
            }
            .onChange(of: detection.meetingDetected) { _, detected in
                if detected { showPrompt() } else { hidePrompt() }
            }
    }

    private func startFromDetection() {
        detection.sessionStarted()
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        liveSession.startLive(context: liveSession.preCallContext,
                              settings: settings,
                              ollamaManager: ollamaManager)
    }

    private var symbol: String {
        // Debug builds get a hammer so a dev copy is never confused with
        // the installed release when both menu bar icons are up.
        #if DEBUG
        return liveSession.isLive ? "hammer.circle.fill" : "hammer.circle"
        #else
        if liveSession.isLive { return "waveform.circle.fill" }
        if detection.meetingDetected { return "waveform.badge.exclamationmark" }
        return "waveform.circle"
        #endif
    }

    private func showPrompt() {
        if promptPanel == nil { promptPanel = MeetingPromptPanel() }
        guard let panel = promptPanel else { return }
        // Rebuild content each detection — the source app can differ.
        let view = MeetingPromptView(detection: detection,
                                     source: detection.detectedSource,
                                     icon: detection.detectedIcon) {
            startFromDetection()
        } onStartWithGoal: {
            detection.sessionStarted()
            liveSession.showPreCallForm = true
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } onDismiss: {
            detection.dismissPrompt()
        }
        panel.contentView = NSHostingView(rootView: view)
        panel.orderFront(nil)
    }

    private func hidePrompt() {
        promptPanel?.orderOut(nil)
    }
}

// MARK: - Menu bar content

struct MenuBarView: View {
    @Bindable var liveSession: LiveSessionViewModel
    @Bindable var settings: SettingsViewModel
    @Bindable var ollamaManager: OllamaManager
    @Bindable var detection: MeetingDetectionService
    let updater: SPUUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if detection.meetingDetected && !liveSession.isLive {
            Button("Meeting detected — Start coaching") {
                startCoaching()
            }
            Button("Not now") {
                detection.dismissPrompt()
            }
            Divider()
        }

        if liveSession.isLive {
            Button(liveSession.isDemo
                   ? "Stop demo"
                   : "Stop coaching (\(liveSession.elapsedFormatted))") {
                liveSession.stopLive()
            }
        } else if !detection.meetingDetected {
            Button("Start coaching") {
                startCoaching()
            }
        }

        Divider()
        Toggle("Auto-detect meetings", isOn: $detection.isEnabled)
        Toggle("Auto-start coaching", isOn: $detection.autoStartEnabled)
            .disabled(!detection.isEnabled)
        Button("Open Meeting Coach") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button(ReferralInvites.invitesLeft > 0
               ? "Give MeetingCoach to a Friend… (\(ReferralInvites.invitesLeft) left)"
               : "Give MeetingCoach to a Friend…") {
            openWindow(id: "give")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Send Feedback…") {
            openWindow(id: "feedback")
            NSApp.activate(ignoringOtherApps: true)
        }
        CheckForUpdatesView(updater: updater)
        Divider()
        // Stops everything: live session teardown and the embedded AI
        // engine both hook app termination.
        Button("Quit Meeting Coach") {
            NSApp.terminate(nil)
        }
    }

    /// Start with the last-used (or default) pre-call context — the setup
    /// ritual is optional from here. The main window is (re)opened first:
    /// ContentView owns the floating overlay, so a session started with no
    /// window would otherwise coach invisibly.
    private func startCoaching() {
        detection.sessionStarted()
        openWindow(id: "main")
        liveSession.startLive(context: liveSession.preCallContext,
                              settings: settings,
                              ollamaManager: ollamaManager)
    }
}

// MARK: - Sparkle menu item

/// "Check for Updates…" menu command, enabled/disabled in sync with the
/// updater (e.g. disabled while an update session is already in progress).
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}
