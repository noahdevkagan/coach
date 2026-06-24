import SwiftUI
import AppKit

/// A floating panel that shows coaching nudges on top of all windows (including Zoom).
/// Uses sharingType = .none so it's invisible during screen shares.
final class CoachingOverlayPanel: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
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
            let x = screen.visibleFrame.maxX - 360
            let y = screen.visibleFrame.maxY - 220
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    // Allow the panel to become key for dragging but not steal focus
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// SwiftUI view shown inside the overlay panel.
struct CoachingOverlayView: View {
    let calls: [CoachingCall]
    let isLive: Bool
    let onClose: () -> Void

    // Show last 3 calls
    private var recentCalls: [CoachingCall] {
        Array(calls.suffix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Circle()
                    .fill(isLive ? .green : .gray)
                    .frame(width: 8, height: 8)
                Text("Meeting Coach")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            if recentCalls.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("Listening...")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
                .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(recentCalls) { call in
                            OverlayNudgeRow(call: call)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(minWidth: 320, maxWidth: 320, minHeight: 80, maxHeight: 240)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(10)
    }
}

private struct OverlayNudgeRow: View {
    let call: CoachingCall

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(call.nudge)
                .font(.callout.bold())
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(call.signalId.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(tierColor.opacity(0.15))
                    .foregroundStyle(tierColor)
                    .clipShape(Capsule())
                Text(call.formattedTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var tierColor: Color {
        let tierA = ["no_decision_owner_date", "alignment_reached_still_talking",
                     "reopening_closed_thread", "buried_signal_ignored"]
        return tierA.contains(call.signalId) ? .blue : .orange
    }
}
