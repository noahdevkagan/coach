import SwiftUI
import AppKit

/// A floating panel that shows coaching nudges on top of all windows (including Zoom).
/// Uses sharingType = .none so it's invisible during screen shares.
final class CoachingOverlayPanel: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 66),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .floating
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        sharingType = .none  // invisible in screen shares

        // A dragged position is the user telling us where the overlay
        // belongs — restore it forever after (Noah moved it repeatedly and
        // every nudge snapped it back to the main screen's top-right).
        if let saved = Self.savedUserFrame(), Self.isOnSomeScreen(saved) {
            setFrame(saved, display: false)
        } else {
            positionAtTopRight(of: NSScreen.main)
        }

        // A display being plugged/unplugged can strand the panel on a
        // screen that no longer exists — re-clamp onto a live one.
        // (Selector-based: this notification posts on the main thread.)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenConfigChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(didMove),
            name: NSWindow.didMoveNotification, object: self)
    }

    @objc private func screenConfigChanged() {
        // Clamp only; the saved preference survives — the user's display
        // will usually come back.
        if screen == nil { repositionProgrammatically { positionAtTopRight(of: NSScreen.main) } }
    }

    // MARK: - User-position memory

    private static let userFrameKey = "coachOverlayUserFrame"
    private var inProgrammaticMove = false

    /// Whether the user has ever dragged the panel (persisted).
    var hasUserPosition: Bool {
        UserDefaults.standard.string(forKey: Self.userFrameKey) != nil
    }

    @objc private func didMove() {
        guard !inProgrammaticMove else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.userFrameKey)
    }

    private func repositionProgrammatically(_ body: () -> Void) {
        inProgrammaticMove = true
        body()
        inProgrammaticMove = false
    }

    private static func savedUserFrame() -> NSRect? {
        guard let s = UserDefaults.standard.string(forKey: userFrameKey) else { return nil }
        let rect = NSRectFromString(s)
        return rect.isEmpty ? nil : rect
    }

    private static func isOnSomeScreen(_ rect: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
    }

    // Allow the panel to become key for dragging but not steal focus
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Move to the screen holding the frontmost app's window — the one the
    /// user is actually looking at (a fullscreen call on a second display).
    /// A user who has ever dragged the panel has picked its home — never
    /// override that (follow-the-action only serves the default position).
    func repositionToActiveScreen() {
        guard !hasUserPosition else { return }
        guard let target = Self.screenOfFrontmostWindow() ?? NSScreen.main else { return }
        if isVisible, screen == target { return }
        repositionProgrammatically { positionAtTopRight(of: target) }
    }

    private func positionAtTopRight(of screen: NSScreen?) {
        guard let screen else { return }
        let x = screen.visibleFrame.maxX - 320
        let y = screen.visibleFrame.maxY - 86
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// The screen containing the frontmost app's biggest on-screen window.
    /// Window bounds (unlike titles) need no Screen Recording permission.
    private static func screenOfFrontmostWindow() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // CG coords: origin top-left of the primary display, y down.
        // Cocoa: origin bottom-left, y up. Convert through primary height.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid == app.processIdentifier,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 200, bounds.height > 150   // skip status items / tooltips
            else { continue }
            let center = NSPoint(x: bounds.midX, y: primaryHeight - bounds.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                return screen
            }
        }
        return nil
    }
}

/// SwiftUI view shown inside the overlay panel: a single-line nudge display
/// with a persistent talk-share meter underneath. Observes the session
/// directly (@Observable), so the meter and nudges update without the host
/// rebuilding the panel's content view.
struct CoachingOverlayView: View {
    var liveSession: LiveSessionViewModel
    var settings: SettingsViewModel
    let onClose: () -> Void

    private var activeNudge: Nudge? { liveSession.activeNudge }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                // Status dot
                Circle()
                    .fill(liveSession.isLive ? .green : .gray)
                    .frame(width: 6, height: 6)

                if let nudge = activeNudge {
                    // Urgency dot (green = reinforcement, not a correction)
                    Circle()
                        .fill(nudgeColor(nudge))
                        .frame(width: 8, height: 8)

                    // Nudge text
                    Text(nudge.text)
                        .font(.callout.bold())
                        .lineLimit(1)

                    Spacer()

                    // Feedback buttons
                    HStack(spacing: 4) {
                        feedbackButton(nudge: nudge, feedback: .useful,
                                       icon: "hand.thumbsup.fill", color: .green)
                        feedbackButton(nudge: nudge, feedback: .annoying,
                                       icon: "minus.circle.fill", color: .gray)
                        feedbackButton(nudge: nudge, feedback: .wrong,
                                       icon: "xmark.circle.fill", color: .red)
                    }
                } else if liveSession.memoryPressureTipVisible {
                    // The overlay is where the user actually looks during a
                    // call — the pressure tip must be actionable here, not
                    // just in a main window buried behind Zoom. The main
                    // window carries the full copy.
                    Text("🐢")
                        .font(.caption)
                    Text("Memory pressure — turn off AI?")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button("Turn off") {
                        liveSession.shedSessionModel(settings: settings)
                    }
                    .font(.caption2)
                    .controlSize(.small)
                    Button("Keep") {
                        liveSession.declineMemoryPressureTip()
                    }
                    .font(.caption2)
                    .controlSize(.small)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else if let notice = liveSession.basicModeNotice {
                    // Degraded coaching would otherwise look identical to a
                    // meeting with nothing to say — name it where the user is
                    // actually looking. The main window carries the fix.
                    Image(systemName: "bolt.slash.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Basic mode — \(notice.cause)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    if settings.showOverlayClock {
                        Text(liveSession.elapsedFormatted)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                } else {
                    // Ambient state
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("Listening...")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    // Session clock — the only always-visible place to see
                    // how long the meeting has run without opening a window.
                    if settings.showOverlayClock {
                        Text(liveSession.elapsedFormatted)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }

                // Close
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Talk-share meter — stays visible under active nudges. The
            // trailing window is what the user can still change; fall back
            // to the session share early on.
            if liveSession.isLive,
               let share = liveSession.talkStats.recentShare ?? liveSession.talkStats.sessionShare {
                TalkMeterBar(share: share)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 280, maxWidth: 300, minHeight: 36)
        // Tint wash under the material while a nudge shows — positives get
        // an unmistakable green; corrections a lighter cue.
        .background(activeNudge.map { nudgeColor($0).opacity($0.type.isPositive ? 0.22 : 0.12) } ?? Color.clear)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(activeNudge.map { nudgeColor($0).opacity(0.55) } ?? Color.primary.opacity(0.08),
                        lineWidth: activeNudge == nil ? 1 : 1.5)
        )
        .padding(6)
        .animation(.easeInOut(duration: 0.3), value: activeNudge?.id)
    }

    private func feedbackButton(nudge: Nudge, feedback: NudgeFeedback, icon: String, color: Color) -> some View {
        Button {
            liveSession.recordFeedback(nudgeId: nudge.id, feedback: feedback)
        } label: {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    private func nudgeColor(_ nudge: Nudge) -> Color {
        if nudge.type.isPositive { return .green }
        switch nudge.urgency {
        case .low: return .gray
        case .med: return .blue
        case .high: return .orange
        }
    }
}

/// Thin two-tone you/them bar with a percentage label. Orange past 65% —
/// the point where coaching notes consistently call the floor hogged.
struct TalkMeterBar: View {
    let share: Double
    var warnAt: Double = TalkStats.warnShare

    var body: some View {
        HStack(spacing: 6) {
            Text("You \(Int(share * 100))%")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(share >= warnAt ? Color.orange : Color.secondary)
                .frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule()
                        .fill(share >= warnAt ? Color.orange : Color.blue)
                        .frame(width: max(3, geo.size.width * share))
                }
            }
            .frame(height: 4)
        }
        .animation(.easeOut(duration: 0.4), value: share)
    }
}
