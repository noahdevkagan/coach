import SwiftUI
import AppKit

/// The "Meeting Detected" pill: a small floating panel at the top-right of
/// the screen when auto-detect spots a live meeting — one click to start
/// coaching without hunting for the menu bar icon. Non-activating, so it
/// never steals focus from the call.
final class MeetingPromptPanel: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 446, height: 78),
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
            let x = screen.visibleFrame.maxX - 462
            let y = screen.visibleFrame.maxY - 94
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Content of the detection pill: pulsing accent, the detected app's real
/// icon, and a compound action — start now, or drop down for goal/dismiss.
struct MeetingPromptView: View {
    let source: String
    /// Real icon of the detected meeting app (Zoom, Teams, the browser…).
    var icon: NSImage?
    let onStart: () -> Void
    var onStartWithGoal: (() -> Void)?
    let onDismiss: () -> Void

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            // Pulsing waveform accent — alive, not alarming.
            HStack(spacing: 3) {
                Capsule().fill(.green)
                    .frame(width: 4, height: pulse ? 26 : 14)
                Capsule().fill(.green.opacity(0.5))
                    .frame(width: 4, height: pulse ? 13 : 22)
            }
            .frame(height: 28)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }

            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
            } else {
                Image(systemName: "video.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: [.green, .green.opacity(0.75)],
                                                 startPoint: .top, endPoint: .bottom))
                    )
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Meeting Detected")
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize()
                Text(source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            // Compound action: big primary target + chevron dropdown.
            HStack(spacing: 0) {
                Button(action: onStart) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Start Coaching")
                            .font(.callout.weight(.semibold))
                            .fixedSize()
                        Text("& open Meeting Coach")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider()
                    .frame(height: 28)

                Menu {
                    if let onStartWithGoal {
                        Button("Start with a goal…", action: onStartWithGoal)
                        Divider()
                    }
                    Button("Not now", action: onDismiss)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: 438)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(4)
    }
}
