import Foundation

// Headless stand-ins for the heavy leaves LiveSessionViewModel touches.
// Everything else in the harness is the app's REAL code (symlinked in
// run.sh) — these stubs exist only because the real types need FluidAudio,
// Yams, or live audio hardware. Keep each surface to exactly what the
// view model calls; a compile error here means the VM grew a dependency
// and the stub should grow with it.

/// One finalized "who spoke when" span (real one lives in SpeakerDiarizer,
/// which imports FluidAudio).
struct SpeakerSegment: Sendable {
    let speaker: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Which audio source a diarization result describes (real one lives in
/// AudioCaptureManager).
enum DiarizationChannel: String, Sendable {
    case mic
    case system
}

/// Capture stub: exposes the same callback surface, records lifecycle
/// calls, never touches audio hardware. Tests drive the VM through these
/// hooks — the same path live capture uses.
@MainActor
final class AudioCaptureManager {
    /// The most recently constructed instance — startLive() news one up
    /// internally, so tests reach the wired instance through here.
    static var last: AudioCaptureManager?

    var contextualHints: [String] = []
    var expectedParticipants: [String] = []
    var vocabulary: VocabularyNormalizer?
    var isMicOnly = false
    var isAppleCall = false
    private(set) var stopped = false
    /// Mirrors the real manager's engine attribution (recorded into saved
    /// sessions); tests can override to assert the header line.
    var engineLabel = "stub"
    var transcriptionEngine: TranscriptionEngine = .parakeetV2
    let language: ResolvedMeetingLanguage
    private(set) var startTime = Date()

    var onUtterance: ((Utterance) -> Void)?
    var onPartialText: ((String, String) -> Void)?
    var onSpeakerSegments: ((DiarizationChannel, [SpeakerSegment]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onSystemAudioLost: (() -> Void)?
    /// Recorded renames (label, name) — the real manager routes these to
    /// the channel diarizers and the voice-profile store.
    private(set) var renames: [(String, String)] = []

    init(language: ResolvedMeetingLanguage) {
        self.language = language
        Self.last = self
    }
    func start() async throws { startTime = Date() }
    func stop() { stopped = true }
    func renameSpeaker(_ label: String, to name: String) { renames.append((label, name)) }
}

/// Minimal rubric: stock tuning, no custom signals.
struct Rubric {
    var builtins: RubricTuning = [:]
    var customSemanticSignals: [CustomSemanticSignal] = []
    static let builtInDefault = Rubric()
}

@MainActor
final class SettingsViewModel {
    var selectedModel = "stub-model"
    var effectiveModel: String { selectedModel }
    var semanticCoachEnabled = false
    var useMock = true
    var defaultMeetingMinutes = 0
    var hasCheckedModels = false
    var ollamaReachable = false
    var availableModels: [OllamaModel] = []
    var meetingLanguage: MeetingLanguageSelection = .english
    func loadRubricOrDefault() throws -> Rubric { Rubric() }

    // Test hooks. The real path reads this machine's free memory and talks to
    // an engine; these let a test choose the outcome and then assert what the
    // view model DID about it.
    /// Ordered record of the lifecycle's steps, so tests can assert sequence
    /// (refresh before resolve, preload before any pin) rather than only the
    /// final stored value.
    private(set) var callLog: [String] = []
    /// Blocks inside refreshModels until released — lets a test land Stop
    /// exactly during the refresh await.
    var refreshGate: (stream: AsyncStream<Void>, cont: AsyncStream<Void>.Continuation)?

    func refreshModels() async {
        callLog.append("refresh")
        if let gate = refreshGate {
            var it = gate.stream.makeAsyncIterator()
            _ = await it.next()
        }
    }
}

@MainActor
final class OllamaManager {
    enum Status: Equatable { case stopped, running, error(String) }
    var status: Status = .stopped
    /// false simulates an engine that won't come up — one of the ways
    /// activation must settle deterministic.
    var engineAvailable = true
    func start() { status = .running }
    func ensureRunning() async -> Bool { engineAvailable }
}
