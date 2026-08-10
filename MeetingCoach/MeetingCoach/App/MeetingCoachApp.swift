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
    private let updaterController: SPUStandardUpdaterController
    // Menu-bar red dot while an update is pending. The badge model is the
    // updater's delegate, so it must exist before the controller does.
    @StateObject private var updateBadge: UpdateBadgeModel

    init() {
        // First line of every run: which binary produced this log. Field
        // debugging 2026-08-10 had to fingerprint the version from log-line
        // *ordering* because nothing ever logged it.
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let commit = info?["MCBuildCommit"] as? String
        mclog("[App] MeetingCoach v\(version) (build \(build))"
              + (commit.map { " @ \($0)" } ?? ""))

        let badge = UpdateBadgeModel()
        _updateBadge = StateObject(wrappedValue: badge)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: badge, userDriverDelegate: nil)
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
                        updater: updaterController.updater,
                        updateBadge: updateBadge)
        } label: {
            // The label view is the app's only always-alive SwiftUI view, so
            // it also owns the floating "Meeting Detected" prompt panel.
            MenuBarLabel(liveSession: liveSession, settings: settings,
                         ollamaManager: ollamaManager, detection: detection,
                         updater: updaterController.updater,
                         updateBadge: updateBadge)
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
                GeneralSettingsView(detection: detection, settings: settings,
                                    updater: updaterController.updater)
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
    let updater: SPUUpdater
    @ObservedObject var updateBadge: UpdateBadgeModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @State private var promptPanel: MeetingPromptPanel?

    var body: some View {
        // Normal state uses a plain SF Symbol (template image — the system
        // recolors it for menu bar appearance). The update badge needs real
        // color, and the menu bar strips color from template images, so that
        // state hand-draws a non-template NSImage: glyph tinted to match the
        // current appearance + a red dot that survives untouched.
        Group {
            if updateBadge.updateAvailable {
                Image(nsImage: Self.badgedIcon(symbol: symbol,
                                               dark: colorScheme == .dark))
            } else {
                Image(systemName: symbol)
            }
        }
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
                if PlatformSupport.neuralModelsSupported {
                    ParakeetDownloadState.shared.startIfNeeded {
                        Task { await settings.autoDownloadRecommendedIfNeeded() }
                    }
                } else {
                    // Intel: no Parakeet download to sequence behind — go
                    // straight to the LLM.
                    Task { await settings.autoDownloadRecommendedIfNeeded() }
                }
                // ContentView also assigns this, but on a login/menu-bar-only
                // launch the main window never opens — without it the engine
                // handle is nil and launch flows silently no-op.
                settings.ollamaManager = ollamaManager
            }
            .onChange(of: liveSession.isLive) { wasLive, isLive in
                // Session-end update reminder: a login-item menu-bar app can
                // run for weeks without the quit that lets Sparkle install
                // its downloaded update (field report 2026-08-10: a week-old
                // CPU fix sitting undelivered). The end of a call is the one
                // natural pause — never during one — so a stale update
                // (3+ days, once a day max) re-surfaces the panel here. The
                // delay lets session teardown and the review UI settle first.
                if wasLive && !isLive && updateBadge.shouldNagNow() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        updater.checkForUpdates()
                    }
                }
            }
            .onChange(of: detection.meetingDetected) { _, detected in
                if detected {
                    showPrompt()
                    // The LLM loads the moment a meeting is detected — early
                    // enough that startLive finds it resident (loading at
                    // minute one of a call froze small-RAM Macs), late
                    // enough that an idle Mac isn't holding multi-GB of
                    // model memory all day (it was: 2h keep-alive from
                    // launch). No-op when no model is installed, one is
                    // downloading, or the pick doesn't fit.
                    Task { await settings.warmUpModelIfNeeded() }
                } else {
                    hidePrompt()
                }
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

    /// Menu-bar icon with the update dot. Non-template on purpose (see body)
    /// — which means light/dark adaptation is on us, via `dark`.
    private static func badgedIcon(symbol: String, dark: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 17)
        let image = NSImage(size: size, flipped: false) { rect in
            let glyphColor: NSColor = dark ? .white : .black
            let config = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .regular)
                .applying(.init(paletteColors: [glyphColor]))
            if let glyph = NSImage(systemSymbolName: symbol,
                                   accessibilityDescription: "MeetingCoach")?
                .withSymbolConfiguration(config) {
                let g = glyph.size
                glyph.draw(in: NSRect(x: (rect.width - g.width) / 2,
                                      y: (rect.height - g.height) / 2,
                                      width: g.width, height: g.height))
            }
            let d: CGFloat = 6.5
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - d, y: rect.maxY - d,
                                        width: d, height: d)).fill()
            return true
        }
        image.isTemplate = false
        return image
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
    @ObservedObject var updateBadge: UpdateBadgeModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The red dot's landing spot: same Sparkle panel the daily check
        // shows, but reachable the moment the user comes looking. Once the
        // update has sat unclaimed a few days the label says so — "available"
        // reads as optional, "waiting N days" reads as overdue.
        if updateBadge.updateAvailable {
            Button {
                updater.checkForUpdates()
            } label: {
                if let days = updateBadge.daysWaiting, days >= UpdateBadgeModel.staleAfterDays {
                    Text("Update waiting \(days) days — Install…")
                } else {
                    Text("Update Available — Install…")
                }
            }
            Divider()
        }

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

// MARK: - Update badge

/// Sparkle updater delegate that drives the menu-bar red dot. The scheduled
/// (daily) check sets it; a later check that finds nothing — including after
/// the user hits "Skip This Version" — clears it. An installed update clears
/// it by relaunching the app. The Sparkle panel still appears as before; the
/// dot just persists after the panel is dismissed.
///
/// It also remembers *when* each update version was first seen (persisted, so
/// relaunches don't reset the clock). A login-item menu-bar app can run for
/// weeks without the quit that lets Sparkle auto-install, so once an update
/// has been waiting `staleAfterDays` the app escalates: the menu item says
/// how long, and the end of a session re-surfaces the update panel (at most
/// once a day, never mid-meeting) — see MenuBarLabel.
final class UpdateBadgeModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published var updateAvailable = false

    static let staleAfterDays = 3
    private static let firstSeenVersionKey = "updateFirstSeenVersion"
    private static let firstSeenDateKey = "updateFirstSeenDate"
    private static let lastNagDateKey = "updateLastNagDate"

    /// Days the currently-offered update has been waiting, or nil when none.
    var daysWaiting: Int? {
        guard updateAvailable,
              let seen = UserDefaults.standard.object(forKey: Self.firstSeenDateKey) as? Date
        else { return nil }
        return Calendar.current.dateComponents([.day], from: seen, to: Date()).day
    }

    var isStale: Bool { (daysWaiting ?? 0) >= Self.staleAfterDays }

    /// True at most once per day while an update is stale — the session-end
    /// reminder consumes this so ending three calls in an afternoon doesn't
    /// nag three times.
    func shouldNagNow() -> Bool {
        guard isStale else { return false }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: Self.lastNagDateKey) as? Date,
           Calendar.current.isDateInToday(last) { return false }
        defaults.set(Date(), forKey: Self.lastNagDateKey)
        return true
    }

    #if DEBUG
    // GUI verification hook — the dot can't be triggered on demand otherwise:
    // defaults write com.coach.MeetingCoach ForceUpdateBadge -bool true
    override init() {
        super.init()
        updateAvailable = UserDefaults.standard.bool(forKey: "ForceUpdateBadge")
    }
    #endif

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let defaults = UserDefaults.standard
        // Keyed by version so a newer release restarts the staleness clock
        // instead of inheriting the previous update's age.
        if defaults.string(forKey: Self.firstSeenVersionKey) != item.versionString {
            defaults.set(item.versionString, forKey: Self.firstSeenVersionKey)
            defaults.set(Date(), forKey: Self.firstSeenDateKey)
        }
        DispatchQueue.main.async { self.updateAvailable = true }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        UserDefaults.standard.removeObject(forKey: Self.firstSeenVersionKey)
        UserDefaults.standard.removeObject(forKey: Self.firstSeenDateKey)
        DispatchQueue.main.async { self.updateAvailable = false }
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
