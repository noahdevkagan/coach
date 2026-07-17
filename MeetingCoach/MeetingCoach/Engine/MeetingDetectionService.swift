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

    /// Default OFF — existing users opt in from the menu bar.
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

    /// True when a meeting looks live and the user hasn't started/dismissed.
    private(set) var meetingDetected = false

    /// Human-readable source shown in the prompt ("Zoom", "Browser meeting").
    private(set) var detectedSource = ""

    /// Wired to the live session so detection pauses during coaching.
    @ObservationIgnored private var isSessionLive: () -> Bool = { false }
    private var detector = MeetingDetector()
    private var pollTask: Task<Void, Never>?

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if isEnabled { startPolling() }
    }

    func bind(liveSession: LiveSessionViewModel) {
        isSessionLive = { [weak liveSession] in liveSession?.isLive ?? false }
    }

    /// User clicked "Not now" — quiet for the cooldown window.
    func dismissPrompt() {
        meetingDetected = false
        detector.dismissed(now: Date().timeIntervalSinceReferenceDate)
    }

    /// A session is starting (from the prompt or manually).
    func sessionStarted() {
        meetingDetected = false
        detector.sessionStarted()
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
        if isSessionLive() {
            detector.sessionStarted()
            meetingDetected = false
            return
        }
        // Candidacy requires the mic first — one cheap CoreAudio property
        // read. Skip the NSWorkspace app enumeration for the (typical)
        // mic-idle tick.
        let micInUse = Self.defaultInputInUse()
        let signals = MeetingSignals(
            micInUse: micInUse,
            meetingAppRunning: micInUse && Self.meetingAppRunning(),
            browserFrontmost: micInUse && Self.browserFrontmost()
        )
        let event = detector.tick(signals, now: Date().timeIntervalSinceReferenceDate)
        if event == .prompt {
            detectedSource = signals.meetingAppRunning
                ? (Self.meetingAppName() ?? "Meeting app")
                : "Browser meeting"
            meetingDetected = true
            mclog("[Detect] Meeting detected (\(signals.meetingAppRunning ? "app" : "browser") + mic)")
            playChirp()
            postNotification()
        } else if meetingDetected, case .idle = detector.state {
            // Signals dropped before the user acted — clear the prompt.
            meetingDetected = false
        }
    }

    // MARK: - Signal adapters

    /// Known meeting app bundle-id prefixes.
    private static let meetingBundlePrefixes = [
        "us.zoom.xos", "com.microsoft.teams", "com.cisco.webex",
        "com.webex.meetingmanager", "com.ringcentral", "com.skype.skype",
        "com.hnc.Discord", "com.loom.desktop",
    ]

    /// Browsers that might host Google Meet / web Zoom.
    private static let browserBundleIds: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
    ]

    /// Some process (not us — detection pauses while live) holds the
    /// default input device open. The OverSight technique: observable
    /// without any permission prompt.
    static func defaultInputInUse() -> Bool {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return false }

        var running: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &runningAddress,
                                         0, nil, &runningSize, &running) == noErr else { return false }
        return running != 0
    }

    static func meetingAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let id = app.bundleIdentifier else { return false }
            return meetingBundlePrefixes.contains { id.hasPrefix($0) }
        }
    }

    /// Display name of the first running known meeting app.
    static func meetingAppName() -> String? {
        let names: [(prefix: String, display: String)] = [
            ("us.zoom.xos", "Zoom"), ("com.microsoft.teams", "Microsoft Teams"),
            ("com.cisco.webex", "Webex"), ("com.webex.meetingmanager", "Webex"),
            ("com.ringcentral", "RingCentral"), ("com.skype.skype", "Skype"),
            ("com.hnc.Discord", "Discord"), ("com.loom.desktop", "Loom"),
        ]
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier else { continue }
            if let match = names.first(where: { id.hasPrefix($0.prefix) }) {
                return match.display
            }
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            mclog("[Detect] notification permission: \(granted)")
        }
    }

    private func postNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Meeting detected"
        content.body = "Start coaching? Open the Meeting Coach menu bar icon."
        let request = UNNotificationRequest(identifier: "meeting-detected-\(UUID().uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
