import SwiftUI
import AppKit

/// The "Meeting Detected" pill: a small floating panel at the top-right of
/// the screen when auto-detect spots a live meeting — one click to start
/// coaching without hunting for the menu bar icon. Non-activating, so it
/// never steals focus from the call.
final class MeetingPromptPanel: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 72),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
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

        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - 396
            let y = screen.visibleFrame.maxY - 88
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Content of the detection pill: source icon, what was detected, and the
/// one action that matters.
struct MeetingPromptView: View {
    let source: String
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "video.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [.green, .green.opacity(0.75)],
                                             startPoint: .top, endPoint: .bottom))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("Meeting Detected")
                    .font(.headline)
                Text(source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button(action: onStart) {
                Text("Start Coaching")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .keyboardShortcut(.defaultAction)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Not now")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 372)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(4)
    }
}
