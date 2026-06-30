import SwiftUI
import AppKit

/// A floating panel that shows coaching nudges on top of all windows (including Zoom).
/// Uses sharingType = .none so it's invisible during screen shares.
final class CoachingOverlayPanel: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 50),
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
            let y = screen.visibleFrame.maxY - 70
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    // Allow the panel to become key for dragging but not steal focus
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// SwiftUI view shown inside the overlay panel — single-line nudge display.
struct CoachingOverlayView: View {
    let activeNudge: Nudge?
    let isLive: Bool
    let onFeedback: (UUID, NudgeFeedback) -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Status dot
            Circle()
                .fill(isLive ? .green : .gray)
                .frame(width: 6, height: 6)

            if let nudge = activeNudge {
                // Urgency dot
                Circle()
                    .fill(urgencyColor(nudge.urgency))
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 280, maxWidth: 300, minHeight: 36)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(activeNudge != nil ? urgencyColor(activeNudge!.urgency).opacity(0.3) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(6)
        .animation(.easeInOut(duration: 0.3), value: activeNudge?.id)
    }

    private func feedbackButton(nudge: Nudge, feedback: NudgeFeedback, icon: String, color: Color) -> some View {
        Button {
            onFeedback(nudge.id, feedback)
        } label: {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    private func urgencyColor(_ urgency: NudgeUrgency) -> Color {
        switch urgency {
        case .low: return .gray
        case .med: return .blue
        case .high: return .orange
        }
    }
}
