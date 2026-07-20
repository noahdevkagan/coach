import SwiftUI
import AppKit

/// The Settings window's General tab: where transcripts live on disk, and
/// the meeting-detection behavior toggles (mirrors of the menu bar ones).
struct GeneralSettingsView: View {
    @Bindable var detection: MeetingDetectionService
    @Bindable var settings: SettingsViewModel

    /// Re-read after "Change…" so the row updates without relaunching.
    @State private var sessionsPath = AppSupport.sessionsDir.path

    private var displayPath: String {
        sessionsPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        Form {
            Section("Transcripts") {
                LabeledContent("Saved to") {
                    Text(displayPath)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Show in Finder") {
                        // The folder is created lazily on first save — make
                        // sure there's something to reveal.
                        try? FileManager.default.createDirectory(
                            at: AppSupport.sessionsDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(AppSupport.sessionsDir)
                    }
                    Button("Change…") { chooseFolder() }
                }
                Text("New sessions save to this folder. Existing transcripts stay where they are — move the files in Finder if you relocate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Coaching overlay") {
                Toggle("Show session timer", isOn: $settings.showOverlayClock)
                Text("A small clock next to \u{201C}Listening\u{201D} in the floating overlay, so you always know how long the meeting has run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Meeting detection") {
                Toggle("Auto-detect meetings", isOn: $detection.isEnabled)
                Toggle("Auto-start coaching", isOn: $detection.autoStartEnabled)
                    .disabled(!detection.isEnabled)
                Text("With auto-start on, coaching begins 10 seconds after a meeting is detected — the pill shows a countdown and one click cancels. Everything stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = AppSupport.sessionsDir
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppSupport.setSessionsDir(url)
        sessionsPath = url.path
    }
}
