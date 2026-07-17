import SwiftUI
import Combine
import Sparkle

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

    var body: some Scene {
        WindowGroup {
            ContentView(ollamaManager: ollamaManager,
                        liveSession: liveSession,
                        settings: settings)
            // Ollama is no longer auto-started on launch.
            // It will be started lazily when post-call review is requested
            // or when running the legacy LLM-based simulation.
        }
        .defaultSize(width: 960, height: 640)
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
                        ollamaManager: ollamaManager, detection: detection)
        } label: {
            Image(systemName: menuBarSymbol)
                .onAppear { detection.bind(liveSession: liveSession) }
        }

        // Preferences (⌘,). Progress moved to the main window's idle pane;
        // this keeps the learned-sensitivity details reachable.
        Settings {
            ScrollView {
                SessionTrendsView()
                    .padding()
            }
            .frame(width: 420, height: 480)
        }
    }

    private var menuBarSymbol: String {
        if liveSession.isLive { return "waveform.circle.fill" }
        if detection.meetingDetected { return "waveform.badge.exclamationmark" }
        return "waveform.circle"
    }
}

// MARK: - Menu bar content

struct MenuBarView: View {
    @Bindable var liveSession: LiveSessionViewModel
    @Bindable var settings: SettingsViewModel
    @Bindable var ollamaManager: OllamaManager
    @Bindable var detection: MeetingDetectionService

    var body: some View {
        if detection.meetingDetected && !liveSession.isLive {
            Button("Meeting detected — Start coaching") {
                startCoaching()
            }
            Button("Start with context…") {
                detection.sessionStarted()
                liveSession.showPreCallForm = true
                NSApp.activate(ignoringOtherApps: true)
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
        Button("Open Meeting Coach") {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Start with the last-used (or default) pre-call context — the setup
    /// ritual is optional from here.
    private func startCoaching() {
        detection.sessionStarted()
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
