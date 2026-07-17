import SwiftUI
import Combine
import Sparkle

@main
struct MeetingCoachApp: App {
    @State private var ollamaManager = OllamaManager()

    // Sparkle auto-updater. startingUpdater: true schedules the background
    // check (respects SUEnableAutomaticChecks in Info.plist); the standard
    // controller shows the familiar "A new version is available" panel with
    // release notes, Download & Install — no custom UI needed.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        WindowGroup {
            ContentView(ollamaManager: ollamaManager)
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
