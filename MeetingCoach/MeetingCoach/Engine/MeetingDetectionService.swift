import AppKit
import CoreAudio
import Foundation
import UserNotifications

/// Adapters around the pure MeetingDetector: polls mic + running-app state
/// every couple of seconds while enabled, publishes `meetingDetected` for
/// the menu bar, and posts an optional local notification on detection.
///
/// Observing the default input's is-running-somewhere property needs no TCC
/// prompt, and NSWorkspace app lists are public — enabling auto-detect asks
/// for nothing except (lazily) notification permission. Capture never
/// starts without the user explicitly confirming.
@MainActor @Observable
final class MeetingDetectionService {
    static let enabledKey = "autoDetectMeetings"
    static let autoStartKey = "autoStartCoaching"

    /// Default ON for fresh installs — detection is permissionless (mic
    /// state + app list, no TCC prompts) and the "Meeting detected" pill is
    /// the product's front door; a new user who never finds the menu bar
    /// toggle would otherwise never see it. An explicit off is respected.
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                requestNotificationPermission()
                startPolling()
            } else {
                stopPolling()
                meetingDetected = false
                detector.reset()
            }
        }
    }

    /// Opt-in: when a meeting is detected, start coaching automatically
    /// after a short cancelable countdown instead of waiting for a click.
    /// Only fires on the per-process attribution path (14.4+) — the
    /// pre-14.4 fallback is too false-positive-prone to auto-record on.
    var autoStartEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoStartEnabled, forKey: Self.autoStartKey)
            if !autoStartEnabled { cancelAutoStart() }
        }
    }

    /// Seconds until coaching auto-starts; nil when no countdown is running.
    /// The detection pill renders this and offers the cancel.
    private(set) var autoStartCountdown: Int?

    /// Fired when the countdown completes — wired to the same start path
    /// as the pill's "Start Coaching" button.
    @ObservationIgnored var onAutoStart: (() -> Void)?
    @ObservationIgnored private var autoStartTask: Task<Void, Never>?

    /// True when a meeting looks live and the user hasn't started/dismissed.
    private(set) var meetingDetected = false

    /// Human-readable source shown in the prompt ("Zoom", "Browser meeting").
    private(set) var detectedSource = ""

    /// Real icon of the detected meeting app (or the browser hosting it).
    private(set) var detectedIcon: NSImage?

    /// Wired to the live session so detection pauses during coaching.
    @ObservationIgnored private var isSessionLive: () -> Bool = { false }
    private var detector = MeetingDetector()
    private var pollTask: Task<Void, Never>?

    init() {
        autoStartEnabled = UserDefaults.standard.bool(forKey: Self.autoStartKey)
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        mclog("[Detect] auto-detect enabled=\(isEnabled) autoStart=\(autoStartEnabled)")
        if isEnabled { startPolling() }
    }

    func bind(liveSession: LiveSessionViewModel) {
        isSessionLive = { [weak liveSession] in liveSession?.isLive ?? false }
        onMeetingEnded = { [weak liveSession, weak self] in
            guard let session = liveSession, session.isLive, !session.isDemo else { return }
            // A released mic can lie (some browsers drop the hold while
            // muted) — only stop when the room has also gone quiet. If
            // people are still talking, skip; the detector keeps reporting
            // .ended every tick while the evidence holds, so this re-runs
            // until the goodbyes trail off (or the meeting resumes).
            //
            // "Talking" must include IN-FLIGHT speech: Parakeet commits in
            // large chunks (100s+ mid-monologue), so the last committed
            // utterance can be minutes old while someone is mid-sentence.
            // A non-empty live partial is direct evidence of active speech.
            guard session.livePartials.values.allSatisfy(\.isEmpty) else {
                mclog("[Detect] Mic released but speech in flight — not auto-stopping")
                return
            }
            let lastHeard = session.utterances.last?.t ?? 0
            guard session.elapsedTime - lastHeard >= 20 else {
                mclog("[Detect] Mic released but speech within 20s — not auto-stopping")
                return
            }
            mclog("[Detect] Meeting ended — auto-stopping session")
            session.stopLive()
            self?.postMeetingEndedNotification()
        }
    }

    /// Fired (on the main actor) when a live session's meeting looks over:
    /// the meeting app/browser released the mic for a sustained window.
    @ObservationIgnored private var onMeetingEnded: (() -> Void)?

    /// User clicked "Not now" — quiet for the cooldown window.
    func dismissPrompt() {
        cancelAutoStart()
        meetingDetected = false
        detector.dismissed(now: Date().timeIntervalSinceReferenceDate)
    }

    /// A session is starting (from the prompt or manually).
    func sessionStarted() {
        cancelAutoStart()
        meetingDetected = false
        windowAbsentStreak = 0
        liveMicHolderIsBrowser = nil
        detector.sessionStarted()
    }

    // MARK: - Auto-start countdown

    /// Ten second cancelable runway between "meeting detected" and capture
    /// starting — a false positive costs one click instead of a recording.
    private func beginAutoStartCountdown() {
        cancelAutoStart()
        autoStartTask = Task { @MainActor [weak self] in
            for remaining in (1...10).reversed() {
                guard let self, !Task.isCancelled else { return }
                self.autoStartCountdown = remaining
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled else { return }
            self.autoStartCountdown = nil
            mclog("[Detect] Auto-starting coaching")
            self.onAutoStart?()
        }
    }

    private func cancelAutoStart() {
        autoStartTask?.cancel()
        autoStartTask = nil
        autoStartCountdown = nil
    }

    // MARK: - Polling

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(2))
                if self == nil { return }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func tick() {
        let now = Date().timeIntervalSinceReferenceDate
        let (rawSignals, attributed) = sampleSignals()
        var signals = rawSignals

        if isSessionLive() {
            meetingDetected = false
            // Starts that didn't route through us (main window button)
            // still put the detector in live mode.
            if !detector.isLive { detector.sessionStarted() }
            // Window evidence only matters while live — skip CGWindowList
            // entirely in every other state.
            signals.meetingWindowPresent = sampleWindowEvidence(signals: rawSignals,
                                                                attributed: attributed)
            // End-of-meeting watch needs per-process attribution — the
            // fallback's device-level mic bit is always on while WE hold
            // the mic to record, so it can never see the meeting end.
            // (Window evidence compounds with attribution on 14.4+; it is
            // deliberately not enough on its own for the pre-14.4 path.)
            if attributed {
                switch detector.tick(signals, now: now) {
                case .ended:
                    onMeetingEnded?()
                case .endedAmbiguous:
                    // Mic long released but a meeting window is still on
                    // screen (muted participant?) — too ambiguous to stop.
                    mclog("[Detect] Mic released but meeting window still visible — not auto-stopping")
                default:
                    break
                }
                // Log arming transitions — when an auto-stop surprises
                // someone, this line says what evidence armed the watch.
                if case .live(let armed, let windowSeen, _) = detector.state,
                   armed != loggedArmed || windowSeen != loggedWindowSeen {
                    mclog("[Detect] end-watch armed=\(armed) windowSeen=\(windowSeen) "
                          + "micHolder=\(micUserForPrompt ?? "none") app=\(signals.meetingAppRunning) "
                          + "browser=\(signals.browserFrontmost) window=\(signals.meetingWindowPresent.map(String.init) ?? "nil")")
                    loggedArmed = armed
                    loggedWindowSeen = windowSeen
                }
            }
            return
        }
        // The session stopped without the detector hearing about it —
        // suppress re-prompting until this meeting's signals drop.
        if detector.isLive { detector.sessionEnded() }
        windowAbsentStreak = 0
        liveMicHolderIsBrowser = nil

        let event = detector.tick(signals, now: now)
        if event == .prompt {
            if let id = micUserForPrompt,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                // Attribution path: name/icon of the process holding the mic.
                detectedSource = Self.displayName(forBundleID: id) ?? app.localizedName ?? "Meeting"
                detectedIcon = app.icon
            } else if signals.meetingAppRunning, let (name, icon) = Self.meetingAppInfo() {
                detectedSource = name
                detectedIcon = icon
            } else if signals.meetingAppRunning {
                detectedSource = "Meeting app"
                detectedIcon = nil
            } else {
                detectedSource = "Browser meeting"
                detectedIcon = NSWorkspace.shared.frontmostApplication?.icon
            }
            meetingDetected = true
            mclog("[Detect] Meeting detected (\(signals.meetingAppRunning ? "app" : "browser") + mic)")
            // Auto-start needs the attribution path's confidence — the
            // pre-14.4 fallback would auto-record on Slack merely running.
            let autoStarting = autoStartEnabled && attributed
            if autoStarting { beginAutoStartCountdown() }
            playChirp()
            postNotification(autoStarting: autoStarting)
        } else if meetingDetected, case .idle = detector.state {
            // Signals dropped before the user acted — clear the prompt.
            cancelAutoStart()
            meetingDetected = false
        }
    }

    /// Sample the environment: who is holding the mic, which meeting apps
    /// are around. `attributed` is true on the per-process path (14.4+).
    private func sampleSignals() -> (MeetingSignals, attributed: Bool) {
        let signals: MeetingSignals
        if let micUsers = Self.micUsingBundleIDs() {
            // Per-process attribution (macOS 14.4+): only a meeting app or a
            // browser actually HOLDING the mic counts. This makes Slack
            // huddles detectable (Slack runs all day; Slack-using-the-mic
            // doesn't) and makes dictation/Siri/Voice Memos structurally
            // invisible (Apple processes are excluded, Safari excepted).
            let relevant = micUsers.filter { id in
                id != Bundle.main.bundleIdentifier
                    && (!id.hasPrefix("com.apple.") || id == "com.apple.Safari")
            }
            let meetingApp = relevant.first { id in
                Self.meetingBundlePrefixes.contains { id.hasPrefix($0) }
            }
            // Browser audio lives in helper processes ("com.google.Chrome
            // .helper" holds the mic for a Meet, not Chrome itself) — match
            // the base browser id or any of its helpers, and report the
            // BASE app so the prompt shows "Google Chrome", not the helper.
            let browser = relevant.compactMap { Self.browserBase(for: $0) }.first
            micUserForPrompt = meetingApp ?? browser
            signals = MeetingSignals(
                micInUse: meetingApp != nil || browser != nil,
                meetingAppRunning: meetingApp != nil,
                browserFrontmost: browser != nil
            )
            return (signals, attributed: true)
        } else {
            // Pre-14.4 fallback: device-level mic state + app list/frontmost.
            micUserForPrompt = nil
            let micInUse = Self.anyInputInUse()
            signals = MeetingSignals(
                micInUse: micInUse,
                meetingAppRunning: micInUse && Self.meetingAppRunning(),
                browserFrontmost: micInUse && Self.browserFrontmost()
            )
            return (signals, attributed: false)
        }
    }

    // MARK: - Window evidence (live sessions only)

    /// Consecutive "no meeting window" samples — absence only reaches the
    /// detector after two in a row, so a Space transition or enumeration
    /// hiccup can't flap the signal.
    @ObservationIgnored private var windowAbsentStreak = 0

    /// Last-logged end-watch arming state (dedupes the diagnostic log).
    @ObservationIgnored private var loggedArmed = false
    @ObservationIgnored private var loggedWindowSeen = false

    /// Whether the live meeting's mic evidence came from a browser (nil
    /// until attribution is seen this session). Browser window titles only
    /// reflect the active tab, so browser absence is never decisive.
    @ObservationIgnored private var liveMicHolderIsBrowser: Bool?

    /// Tri-state window evidence for the live session, smoothed. Titles in
    /// CGWindowList are only populated with Screen Recording permission —
    /// which the app already needs for system audio, so this asks for
    /// nothing new; without it we return nil and behavior is unchanged.
    private func sampleWindowEvidence(signals: MeetingSignals, attributed: Bool) -> Bool? {
        if attributed, signals.micInUse {
            liveMicHolderIsBrowser = !signals.meetingAppRunning
        }
        guard CGPreflightScreenCaptureAccess() else {
            windowAbsentStreak = 0
            return nil
        }
        let raw = MeetingWindowHeuristics.evaluate(
            windows: Self.meetingWindowSnapshot(),
            zoomRunning: Self.appRunning(prefix: "us.zoom.xos"),
            slackRunning: Self.appRunning(prefix: "com.tinyspeck.slackmacgap"),
            micHolderIsBrowser: liveMicHolderIsBrowser ?? true)
        switch raw {
        case .some(true):
            windowAbsentStreak = 0
            return true
        case .some(false):
            windowAbsentStreak += 1
            return windowAbsentStreak >= 2 ? false : nil
        case .none:
            windowAbsentStreak = 0
            return nil
        }
    }

    /// All-Spaces window snapshot (owner + title) — `.optionAll`, not
    /// on-screen-only, so a meeting window minimized or on another Space
    /// doesn't read as absent.
    private static func meetingWindowSnapshot() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  let title = info[kCGWindowName as String] as? String, !title.isEmpty
            else { return nil }
            return WindowInfo(ownerName: owner, title: title)
        }
    }

    private static func appRunning(prefix: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier?.hasPrefix(prefix) ?? false
        }
    }

    // MARK: - Signal adapters

    /// The mic-holding bundle id backing the current candidacy (attribution
    /// path only) — names the prompt precisely ("Slack", not "Meeting app").
    @ObservationIgnored private var micUserForPrompt: String?

    /// Known meeting app bundle-id prefixes. Slack is only safe here because
    /// the attribution path requires it to be USING the mic (a huddle) —
    /// on the pre-14.4 fallback, Slack merely running would false-positive,
    /// which is acceptable for the small pre-14.4 population.
    private static let meetingBundlePrefixes = [
        "us.zoom.xos", "com.microsoft.teams", "com.cisco.webex",
        "com.webex.meetingmanager", "com.ringcentral", "com.skype.skype",
        "com.hnc.Discord", "com.loom.desktop", "com.tinyspeck.slackmacgap",
    ]

    /// Friendly names for the prompt, keyed by bundle-id prefix.
    private static let displayNames: [(prefix: String, display: String)] = [
        ("us.zoom.xos", "Zoom"), ("com.microsoft.teams", "Microsoft Teams"),
        ("com.cisco.webex", "Webex"), ("com.webex.meetingmanager", "Webex"),
        ("com.ringcentral", "RingCentral"), ("com.skype.skype", "Skype"),
        ("com.hnc.Discord", "Discord"), ("com.loom.desktop", "Loom"),
        ("com.tinyspeck.slackmacgap", "Slack huddle"),
    ]

    static func displayName(forBundleID id: String) -> String? {
        displayNames.first { id.hasPrefix($0.prefix) }?.display
    }

    /// The known browser id that `id` belongs to — itself or one of its
    /// helper processes (Chromium audio runs in "<browser>.helper").
    static func browserBase(for id: String) -> String? {
        browserBundleIds.first { id == $0 || id.hasPrefix($0 + ".") }
    }

    /// Bundle IDs of processes currently recording from any input device
    /// (macOS 14.4+ AudioHardware process objects). nil when the API is
    /// unavailable — callers fall back to device-level detection.
    static func micUsingBundleIDs() -> Set<String>? {
        guard #available(macOS 14.4, *) else { return nil }
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var listSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &listAddress, 0, nil, &listSize) == noErr,
              listSize > 0 else { return nil }
        var processes = [AudioObjectID](repeating: 0,
                                        count: Int(listSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &listAddress, 0, nil, &listSize, &processes) == noErr
        else { return nil }

        var users: Set<String> = []
        for proc in processes {
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(proc, &runningAddress, 0, nil,
                                             &runningSize, &running) == noErr,
                  running != 0 else { continue }

            var bundleAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var bundleRef: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(proc, &bundleAddress, 0, nil,
                                             &bundleSize, &bundleRef) == noErr,
                  let id = bundleRef?.takeRetainedValue() as String?, !id.isEmpty
            else { continue }
            users.insert(id)
        }
        return users
    }

    /// Browsers that might host Google Meet / web Zoom.
    private static let browserBundleIds: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "company.thebrowser.dia", "ai.perplexity.comet", "com.kagi.kagimacOS",
    ]

    /// Some process (not us — detection pauses while live) holds ANY input
    /// device open — not just the default one. Meets run on AirPods or a
    /// headset that isn't the system default input, and the default-only
    /// check missed those entirely. The OverSight technique: observable
    /// without any permission prompt.
    static func anyInputInUse() -> Bool {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var listSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &listAddress, 0, nil, &listSize) == noErr else { return false }
        var deviceIDs = [AudioDeviceID](repeating: 0,
                                        count: Int(listSize) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &listAddress, 0, nil, &listSize, &deviceIDs) == noErr else { return false }

        for id in deviceIDs {
            // Input-capable devices only (spares output-only churn).
            var cfgAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var cfgSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &cfgAddress, 0, nil, &cfgSize) == noErr,
                  cfgSize > 0 else { continue }
            let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(cfgSize), alignment: 8)
            defer { buf.deallocate() }
            guard AudioObjectGetPropertyData(id, &cfgAddress, 0, nil, &cfgSize, buf) == noErr else { continue }
            let abl = buf.assumingMemoryBound(to: AudioBufferList.self)
            let channels = UnsafeMutableAudioBufferListPointer(abl)
                .reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channels > 0 else { continue }

            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(id, &runningAddress, 0, nil,
                                          &runningSize, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }

    static func meetingAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let id = app.bundleIdentifier else { return false }
            return meetingBundlePrefixes.contains { id.hasPrefix($0) }
        }
    }

    /// Display name + real icon of the first running known meeting app.
    /// Reuses the displayNames table — a second inline copy drifted once.
    static func meetingAppInfo() -> (name: String, icon: NSImage?)? {
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier,
                  meetingBundlePrefixes.contains(where: { id.hasPrefix($0) }),
                  let display = displayName(forBundleID: id)
            else { continue }
            return (display, app.icon)
        }
        return nil
    }

    static func browserFrontmost() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return browserBundleIds.contains(id)
    }

    // MARK: - Chirp

    /// Retained while playing — a local NSSound can deallocate mid-chirp.
    @ObservationIgnored private var chirp: NSSound?

    /// A cute bird chirp announces the detection pill. Quiet on purpose —
    /// the user is about to be on a call.
    private func playChirp() {
        guard let url = Bundle.main.url(forResource: "bird_chirp", withExtension: "wav") else { return }
        let sound = NSSound(contentsOf: url, byReference: true)
        sound?.volume = 0.5
        chirp = sound
        sound?.play()
    }

    // MARK: - Notifications (optional, lazily authorized)

    private func requestNotificationPermission() {
        // Async form on purpose: the callback variant runs its completion on
        // the notification service's private queue, and a closure formed in
        // this @MainActor context tripped the Swift executor assertion there
        // (dispatch_assert_queue_fail crash on UNUserNotificationService
        // call-out, seen in the wild on 0.5.4).
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert])) ?? false
            mclog("[Detect] notification permission: \(granted)")
        }
    }

    private func postNotification(autoStarting: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting detected"
        content.body = autoStarting
            ? "Coaching starts in 10 seconds — click the pill to cancel."
            : "Start coaching? Open the Meeting Coach menu bar icon."
        let request = UNNotificationRequest(identifier: "meeting-detected-\(UUID().uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func postMeetingEndedNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Meeting ended"
        content.body = "Coaching stopped — your session recap is ready."
        let request = UNNotificationRequest(identifier: "meeting-ended-\(UUID().uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
