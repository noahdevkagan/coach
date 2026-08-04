import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One vocabulary rule as the user thinks of it: the error → the fix.
/// Backed by the same "Canonical = garble, garble" line format the
/// normalizer parses and the transcript fix-flow appends to. File-scoped
/// (not nested in the view): a type nested in a View inherits its
/// main-actor isolation, which Swift 6 rejects for the synthesized
/// Equatable/Identifiable conformances.
struct VocabEntry: Identifiable, Equatable {
    let id = UUID()
    var wrote: String   // what the transcriber wrote (comma-separated)
    var term: String    // what it should be
}

/// The Settings window's General tab: where transcripts live on disk, and
/// the meeting-detection behavior toggles (mirrors of the menu bar ones).
struct GeneralSettingsView: View {
    @Bindable var detection: MeetingDetectionService
    @Bindable var settings: SettingsViewModel

    /// Re-read after "Change…" so the row updates without relaunching.
    @State private var sessionsPath = AppSupport.sessionsDir.path

    /// Custom transcription vocabulary — same store the live pipeline and
    /// the transcript's "Fix a misheard term" flow write to.
    @AppStorage("customVocabularyText") private var vocabularyText = ""

    /// Editable row mirror of `vocabularyText` (see parseVocab/serializeVocab).
    @State private var vocabEntries: [VocabEntry] = []

    // Granola import state
    @State private var isImporting = false
    @State private var importResult: String?
    @State private var importResultIsError = false

    private var displayPath: String {
        sessionsPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Start MeetingCoach at login", isOn: $settings.launchAtLogin)
                Text("Opens MeetingCoach automatically after a restart or log-in, so meeting detection is ready before your first call. Also manageable under System Settings \u{2192} General \u{2192} Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

            Section("Import from Granola") {
                HStack {
                    Button("Import Granola export (CSV)…") { importGranolaCSV() }
                        .disabled(isImporting)
                    if isImporting {
                        ProgressView().controlSize(.small)
                    }
                }
                if let importResult {
                    Text(importResult)
                        .font(.caption)
                        .foregroundStyle(importResultIsError ? .red : .secondary)
                }
                Text("In Granola, enable data export and download your meetings as a CSV, then pick that file here. Your notes become MeetingCoach sessions — searchable, on this Mac, in your transcripts folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Coaching overlay") {
                Toggle("Show session timer", isOn: $settings.showOverlayClock)
                Text("A small clock next to \u{201C}Listening\u{201D} in the floating overlay, so you always know how long the meeting has run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Meeting length") {
                Picker("Default length", selection: $settings.defaultMeetingMinutes) {
                    Text("Not timed").tag(0)
                    ForEach([15, 25, 30, 45, 60], id: \.self) { min in
                        Text("\(min) min").tag(min)
                    }
                }
                Text("Arms the time-based nudges (time check, next-steps countdown, overrun) on every call started without a scheduled duration. \u{201C}Not timed\u{201D} keeps them off unless you set a duration in the goal form.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Vocabulary") {
                ForEach($vocabEntries) { $entry in
                    HStack(spacing: 8) {
                        TextField("It wrote…", text: $entry.wrote)
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        TextField("Corrected to…", text: $entry.term)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            vocabEntries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this term")
                    }
                }
                Button {
                    vocabEntries.append(VocabEntry(wrote: "", term: ""))
                } label: {
                    Label("Add term", systemImage: "plus")
                }
                Text("Terms the transcriber keeps mishearing: what it wrote (comma-separate variants, e.g. utc, u g c) and what it should be. Leave \u{201C}it wrote\u{201D} empty to just teach a spelling. Clicking a misheard word in any transcript adds a row here automatically. Built in already: \(VocabularyNormalizer.defaultTerms.map(\.canonical).joined(separator: ", ")).")
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

            Section("Agent access (MCP)") {
                if let path = mcpHelperPath {
                    Button(mcpCopied ? "Copied ✓" : "Copy setup command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "claude mcp add meetingcoach -- \"\(path)\"",
                            forType: .string)
                        mcpCopied = true
                    }
                }
                Text(mcpHelperPath == nil
                     ? "Agent server not found in this build."
                     : "Lets Claude and other agents search and read your saved transcripts. Runs locally over stdio; nothing leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { syncVocabFromStorage() }
        // The transcript's "Fix a misheard term" flow writes to the same
        // store — refresh the rows if it changes while Settings is open.
        .onChange(of: vocabularyText) { _, _ in syncVocabFromStorage() }
        .onChange(of: vocabEntries) { _, _ in
            let serialized = Self.serializeVocab(vocabEntries)
            if serialized != vocabularyText { vocabularyText = serialized }
        }
    }

    // MARK: - Vocabulary rows

    private func syncVocabFromStorage() {
        let parsed = Self.parseVocab(vocabularyText)
        // Ignore round-trip echoes of our own serialization, so rows keep
        // their identity (and focus) while the user is typing in them —
        // including a half-finished row that serialization skips.
        guard Self.serializeVocab(parsed) != Self.serializeVocab(vocabEntries) else { return }
        vocabEntries = parsed
    }

    static func parseVocab(_ text: String) -> [VocabEntry] {
        text.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard let head = parts.first?.trimmingCharacters(in: .whitespaces),
                  !head.isEmpty, !head.hasPrefix("#") else { return nil }
            let garbles = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            return VocabEntry(wrote: garbles, term: head)
        }
    }

    static func serializeVocab(_ entries: [VocabEntry]) -> String {
        entries.compactMap { entry in
            let term = entry.term.trimmingCharacters(in: .whitespaces)
            let wrote = entry.wrote.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { return nil }   // half-finished row
            return wrote.isEmpty ? term : "\(term) = \(wrote)"
        }
        .joined(separator: "\n")
    }

    @State private var mcpCopied = false

    private var mcpHelperPath: String? {
        Bundle.main.url(forAuxiliaryExecutable: "meetingcoach-mcp")?.path
    }

    // MARK: - Granola import

    private func importGranolaCSV() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsOtherFileTypes = true
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        isImporting = true
        importResult = nil
        // Inner detached task keeps the file IO off the main thread without
        // capturing the view; results hop back here (MainActor) to publish.
        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try GranolaImporter.importCSV(url)
                }.value
                importResult = report.summary
                importResultIsError = false
            } catch {
                importResult = error.localizedDescription
                importResultIsError = true
            }
            isImporting = false
        }
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
