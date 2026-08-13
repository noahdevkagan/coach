import SwiftUI
import AppKit
import Sparkle
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
    let updater: SPUUpdater

    /// Re-read after "Change…" so the row updates without relaunching.
    @State private var sessionsPath = AppSupport.sessionsDir.path

    /// Mirror of Sparkle's automaticallyDownloadsUpdates (an NSObject
    /// property SwiftUI can't observe directly). Synced on appear, written
    /// through on toggle; Sparkle persists it to UserDefaults itself.
    @State private var autoInstallUpdates = true

    /// Custom transcription vocabulary — same store the live pipeline and
    /// the transcript's "Fix a misheard term" flow write to.
    @AppStorage("customVocabularyText") private var vocabularyText = ""

    /// Editable row mirror of `vocabularyText` (see parseVocab/serializeVocab).
    @State private var vocabEntries: [VocabEntry] = []

    /// Transient "Saved" confirmation for vocabulary edits — rows persist on
    /// every keystroke, but silently, which read as "did it save?".
    /// `vocabSaveCount` bumps per persisted edit; `.task(id:)` on it restarts
    /// the fade-out timer (CI's Xcode 16.2 SDK rejects a hand-rolled Task
    /// capturing the view from a nonisolated method under Swift 6).
    @State private var vocabSavedFlash = false
    @State private var vocabSaveCount = 0

    // Granola import state
    @State private var isImporting = false
    @State private var importResult: String?
    @State private var importResultIsError = false

    private var displayPath: String {
        sessionsPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        let resolvedLanguage = settings.resolvedMeetingLanguage
        Form {
            Section("Startup") {
                Toggle("Start MeetingCoach at login", isOn: $settings.launchAtLogin)
                Text("Opens MeetingCoach automatically after a restart or log-in, so meeting detection is ready before your first call. Also manageable under System Settings \u{2192} General \u{2192} Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Software updates") {
                Toggle("Install updates automatically", isOn: $autoInstallUpdates)
                Text("Updates download in the background and install the next time the app isn't running \u{2014} never during a meeting. Turn this off to review each update yourself; the menu bar dot will tell you when one is waiting.")
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
                Toggle("Show floating overlay during meetings", isOn: $settings.showCoachOverlay)
                Text("The small \u{201C}Listening\u{201D} pill that floats above your call. Turn it off and nudges appear only in the Meeting Coach window. Wherever you drag it, it stays.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show session timer", isOn: $settings.showOverlayClock)
                    .disabled(!settings.showCoachOverlay)
                Text("A small clock next to \u{201C}Listening\u{201D} in the floating overlay, so you always know how long the meeting has run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Meeting language") {
                Picker("Transcribe meetings in", selection: $settings.meetingLanguage) {
                    ForEach(MeetingLanguageSelection.allCases) { language in
                        Text(language == .system
                             ? "Mac language (\(MeetingLanguageSelection.system.resolved().englishName))"
                             : language.pickerName)
                            .tag(language)
                    }
                }

                if let wanted = resolvedLanguage.intelFallbackFrom {
                    Text("\(wanted.englishName) transcription requires Apple Silicon, so this Intel Mac transcribes meetings in English with Apple's on-device engine.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if resolvedLanguage.usedUnsupportedSystemFallback {
                    Text("Your Mac language isn't supported yet, so meetings use English. Choose another supported language here if needed.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !PlatformSupport.neuralModelsSupported {
                    Text("This Intel Mac transcribes English with Apple's built-in engine. The high-accuracy engine and speaker naming need Apple Silicon.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(resolvedLanguage.isEnglish
                         ? "Required engine: Parakeet v2 for English. It downloads once (~600 MB)."
                         : "Required engine: Parakeet v3 for \(resolvedLanguage.englishName). It downloads once (~600 MB); live coaching is limited to talk time, voice share, and overrun.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("The selection is captured when a meeting starts. Changes take effect next meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if PlatformSupport.neuralModelsSupported {
                    ParakeetProgressLine(engine: resolvedLanguage.preferredEngine)
                }
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
                ForEach(vocabEntries) { entry in
                    let row = $vocabEntries.safeElement(entry)
                    HStack(spacing: 8) {
                        TextField("It wrote…", text: row.wrote)
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        TextField("Corrected to…", text: row.term)
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
                HStack {
                    Button {
                        vocabEntries.append(VocabEntry(wrote: "", term: ""))
                    } label: {
                        Label("Add term", systemImage: "plus")
                    }
                    Spacer()
                    if hasUnfinishedVocabRow {
                        Text("Fill in \u{201C}Corrected to\u{2026}\u{201D} to save the row")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if vocabSavedFlash {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
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
        .onAppear {
            syncVocabFromStorage()
            autoInstallUpdates = updater.automaticallyDownloadsUpdates
        }
        .onChange(of: autoInstallUpdates) { _, on in
            updater.automaticallyDownloadsUpdates = on
        }
        // The transcript's "Fix a misheard term" flow writes to the same
        // store — refresh the rows if it changes while Settings is open.
        .onChange(of: vocabularyText) { _, _ in syncVocabFromStorage() }
        .onChange(of: vocabEntries) { _, _ in
            let serialized = Self.serializeVocab(vocabEntries)
            if serialized != vocabularyText {
                vocabularyText = serialized
                vocabSaveCount += 1
            }
        }
        .task(id: vocabSaveCount) {
            guard vocabSaveCount > 0 else { return }
            withAnimation { vocabSavedFlash = true }
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation { vocabSavedFlash = false }
        }
    }

    // MARK: - Vocabulary rows

    /// A row typed into but missing its "corrected to" term — serialization
    /// skips it, so tell the user instead of silently not saving.
    private var hasUnfinishedVocabRow: Bool {
        vocabEntries.contains {
            $0.term.trimmingCharacters(in: .whitespaces).isEmpty &&
            !$0.wrote.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

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
