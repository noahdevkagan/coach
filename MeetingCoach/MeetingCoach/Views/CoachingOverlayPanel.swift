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

        // Position at top-right of main screen
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - 320
            let y = screen.visibleFrame.maxY - 86
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    // Allow the panel to become key for dragging but not steal focus
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(activeNudge.map { nudgeColor($0).opacity(0.3) } ?? Color.primary.opacity(0.08), lineWidth: 1)
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
