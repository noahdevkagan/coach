import Foundation
import SwiftUI

/// Manages a live coaching session: audio capture → transcription → deterministic signals → nudges.
@MainActor @Observable
final class LiveSessionViewModel {
    var isLive = false
    var utterances: [Utterance] = []
    /// Coalesced speaker turns (built incrementally by the signal engine) —
    /// the UI renders these instead of re-joining fragments every frame.
    var turns: [Turn] = []

    /// In-flight recognizer text per speaker, rendered as a live pending
    /// line under the committed transcript. Cleared on emit/stop.
    var livePartials: [String: String] = [:]

    /// Capture couldn't get system audio this session (Screen Recording
    /// declined) — the transcript can't tell You from the meeting.
    var micOnly = false

    /// Mic-only because an Apple call (FaceTime/iPhone relay) was active —
    /// deliberate, not a permissions problem. The banner must explain the
    /// call-audio limitation instead of sending users to Screen Recording.
    var appleCallCapture = false

    /// This session transcribed on the SFSpeech fallback (high-accuracy
    /// Parakeet model not ready — usually still downloading on a fresh
    /// install). Fragmented "random words" transcripts are expected on
    /// this engine; the UI must say so or users blame settings.
    var usedFallbackEngine = false

    /// Language policy resolved once at start and retained through save/review.
    /// It intentionally survives Settings changes made during the meeting.
    private(set) var sessionLanguage: ResolvedMeetingLanguage?

    /// Wall-clock moment the session started — exports stamp utterances
    /// with real times of day, like other tools' transcripts.
    private(set) var sessionStartDate: Date?
    var nudges: [Nudge] = []
    var activeNudge: Nudge?
    /// Live word-share meter data (you vs. them), updated with each
    /// signal evaluation. Empty in mic-only mode.
    var talkStats = TalkStats()
    var error: String?
    var status: String = ""
    var elapsedTime: TimeInterval = 0
    var preCallContext = PreCallContext()

    /// Supplies the live meeting's real name at save time (wired to the
    /// detection service's window-title capture by the App; nil-returning
    /// when nothing nameable was seen).
    @ObservationIgnored var meetingTitleProvider: (() -> String?)?

    /// End-of-meeting review (structured — both the deterministic and the
    /// LLM path produce the same MeetingReview shape).
    var meetingReview: MeetingReview?
    var isGeneratingSummary = false

    /// Indices into preCallContext.plannedQuestions that have been covered —
    /// auto-detected (keyword overlap against the user's turns, re-derived
    /// each tick) or ticked by hand in the live checklist.
    var askedPlannedQuestions: Set<Int> = []
    /// Indices the user unchecked by hand. Auto-coverage only ever adds, so
    /// without this pin a false-positive match would re-tick on the next turn.
    private var manuallyUncheckedQuestions: Set<Int> = []
    var savedPath: String?
    var showPostSession = false

    /// Pre-call form
    var showPreCallForm = false

    /// Demo replay: the bundled sample meeting playing through the real
    /// pipeline. Demo sessions are never saved and never train adaptation.
    private(set) var isDemo = false
    private var demoTask: Task<Void, Never>?

    /// Silence detection — nudge user to stop if meeting seems over
    var showSilenceWarning = false
    /// The silence looks like a capture failure (nothing was ever really
    /// heard), not a finished meeting — drives the warning card's copy.
    var silenceLooksLikeCaptureGap = false
    private var silenceCheckTask: Task<Void, Never>?
    private let silenceThreshold: TimeInterval = 180  // 3 minutes

    private var captureManager: AudioCaptureManager?
    private var captureStartTask: Task<Void, Never>?
    private var signalTickTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var signalEngine: SignalEngine?
    private var dismissTask: Task<Void, Never>?
    /// Overlay fatigue guard — consecutive ignored nudges quiet the overlay
    /// for the rest of the session until the user interacts again.
    private var backoff = NudgeBackoff()

    // Tier-2 semantic coaching (local LLM heartbeat)
    private var semanticCoach: SemanticCoach?
    private var semanticTask: Task<Void, Never>?

    // Speaker identity
    /// LLM-inferred name suggestions awaiting a one-tap confirm ("Them 1
    /// sounds like Sarah"). Confirming routes through renameSpeaker.
    var speakerNameSuggestions: [SpeakerNameSuggestion] = []
    private var rejectedNameSuggestions: Set<String> = []
    private var nameInference: SpeakerNameInference?
    /// Every label each diarization channel has published (plus renames) —
    /// relabeled utterances must stay eligible for refined segments.
    private var channelLabels: [DiarizationChannel: Set<String>] = [:]
    /// Renames of the undiarized base labels ("Them" → "William"), applied
    /// to utterances as they arrive.
    private var baseLabelRenames: [String: String] = [:]
    /// Every rename ever applied ("Them 2" → "William"). Incoming segments
    /// are remapped through this: a publish already in flight when the user
    /// renamed still carries the old label and would revert the transcript.
    private var segmentRenames: [String: String] = [:]
    /// The capture manager of the just-ended session — kept so renaming a
    /// speaker from the post-session view can still save their voice clip.
    private var endedCaptureManager: AudioCaptureManager?
    /// One-on-one alias: the sole remote participant's name, applied to
    /// "Them"-family labels at DISPLAY time only (see displaySpeaker) —
    /// stored utterance labels stay raw, so a second remote voice showing
    /// up just drops the alias and the numbered labels are back instantly.
    private(set) var remoteAlias: String?
    /// Distinct remote voices in the system channel's latest publish. This
    /// is fallback evidence only: diarization can create a stray speaker
    /// segment that never claims any transcript speech, so transcript-backed
    /// labels take precedence when deciding whether a call is one-on-one.
    private var latestRemoteLabels: Set<String> = []
    /// Exactly one pre-call participant seeds the provisional remote name.
    private var preCallRemoteName: String?

    /// Signal types sharpened by the active focus goals (set per session).
    private var focusTypes: Set<NudgeType> = []
    /// A meeting's relationship to the local model, over its whole lifetime.
    ///
    /// Every state carries the session's UUID so a continuation resuming after
    /// an await can tell whether it still belongs to the meeting in progress.
    /// Activation is asynchronous — it waits for capture, refreshes the model
    /// list, reads memory and preloads — and any of those awaits can outlive a
    /// Stop or be overtaken by a new session.
    ///
    /// - `preparing`: capture is up, the model question is still open. No LLM
    ///   call may happen yet, including a recap.
    /// - `deterministic`: settled. Nothing safe can be loaded, so this meeting
    ///   makes no LLM calls at all. Binding through the recap.
    /// - `pinned`: this exact model is resident, and is the only one the
    ///   heartbeat, name inference, recap and unload may name.
    enum SessionModelState: Equatable {
        case preparing(UUID)
        case deterministic(UUID)
        case pinned(UUID, String)

        var sessionID: UUID {
            switch self {
            case .preparing(let id), .deterministic(let id): return id
            case .pinned(let id, _): return id
            }
        }

        /// The resident model, or nil while preparing or when deterministic.
        var pinnedModel: String? {
            if case .pinned(_, let model) = self { return model }
            return nil
        }
    }

    private(set) var sessionModelState: SessionModelState?

    /// Why coaching is running without an LLM this session, in words the
    /// banner can show. Set only for degraded causes the user didn't choose
    /// (low memory, engine down, load failure) — mock mode and the internal
    /// kill-switch stay silent, they're not failures. nil while preparing,
    /// pinned, or deterministic-by-choice.
    struct BasicModeNotice: Equatable {
        /// Short cause for the headline, e.g. "low memory".
        let cause: String
        /// One-sentence detail with the fix, for the expanded banner.
        let detail: String
        /// True when memory was the blocker — the banner offers to download
        /// the small fallback model iff it would actually have helped.
        var lowMemory: Bool = false
    }
    private(set) var basicModeNotice: BasicModeNotice?

    // Seams for the four things this lifecycle cannot do in a test: read this
    // machine's free memory, and load, unload or query a model in a live engine.
    // Production wiring is the default; the session harness substitutes them
    // so preload failure, memory pressure and cancellation are exercised
    // exactly rather than depending on what the test machine happens to have.
    // Defaults are nonisolated statics, not inline closures: an inline
    // closure touching the OllamaClient actor is an actor-isolated default
    // value in a @MainActor type, which strict concurrency rejects.
    /// Free memory heuristic, in GB. nil = unreadable.
    static var availableMemoryGB: () -> Double? = liveAvailableMemoryGB
    /// Loads a model. Returns an error string, or nil on success.
    static var preloadModel: (String) async -> String? = livePreload
    /// Frees a model if it is resident.
    static var unloadModel: (String) async -> Void = liveUnload
    /// Runs the post-call review prompt against the pinned model.
    static var completeReview: (String, String, String) async throws -> String = liveCompleteReview

    nonisolated static func liveAvailableMemoryGB() -> Double? { ModelMemory.availableGB }
    nonisolated static func livePreload(_ model: String) async -> String? {
        await OllamaClient(model: model, numCtx: 4096).preload()
    }
    nonisolated static func liveUnload(_ model: String) async {
        await OllamaClient(model: model).unloadIfLoaded()
    }
    nonisolated static func liveCompleteReview(_ model: String,
                                               _ system: String,
                                               _ user: String) async throws -> String {
        try await OllamaClient(model: model).complete(system: system, user: user)
    }

    /// The meeting currently in progress. Set at start, cleared at Stop —
    /// every continuation compares against it before touching state, so a
    /// stopped or replaced session cannot pin a model or start a heartbeat.
    private var currentSessionID: UUID?

    /// The in-flight activation, held so Stop (or a replacing session) can
    /// cancel it rather than racing it.
    private var activationTask: Task<Void, Never>?

    /// Coach inputs captured at startLive, consumed once capture is up. Tier 2
    /// can only be armed after the memory reading is meaningful, but its
    /// rubric-derived inputs are computed with the rest of session setup.
    private var pendingCoachSetup: (tuning: RubricTuning,
                                    customSignals: [CustomSemanticSignal],
                                    noteExamples: [String: [SignalExample]])?

    /// Held across the session so stopLive can auto-generate the recap —
    /// weak: both outlive sessions anyway, and the VM must never keep an
    /// app-level object alive.
    private weak var lastSettings: SettingsViewModel?
    private weak var lastOllamaManager: OllamaManager?
    /// Stashed at stop (the capture manager is torn down before save) so
    /// the saved session records which transcription engine actually ran.
    private var sessionEngineLabel: String?

    var elapsedFormatted: String {
        let mm = Int(elapsedTime) / 60
        let ss = Int(elapsedTime) % 60
        return String(format: "%02d:%02d", mm, ss)
    }

    var hasSession: Bool {
        !nudges.isEmpty || !utterances.isEmpty
    }

    /// Most recent text heard (for status display)
    var lastHeard: String {
        guard let last = utterances.last else { return "" }
        let preview = last.text.prefix(60)
        return "[\(last.speaker)] \(preview)\(last.text.count > 60 ? "..." : "")"
    }

    /// All utterances joined into one flowing transcript
    var fullTranscript: String {
        utterances.map(\.text).joined(separator: " ")
    }

    // MARK: - Start / Stop

    func startLive(context: PreCallContext, settings: SettingsViewModel? = nil, ollamaManager: OllamaManager? = nil) {
        guard !isLive else { return }

        isDemo = false
        let resolvedLanguage = (settings?.meetingLanguage ?? MeetingLanguageSelection.current).resolved()
        preCallContext = context
        // Untimed call + a default length in Settings = the user wants the
        // time nudges on every call without filling the form each time.
        if preCallContext.scheduledDurationMinutes == 0,
           let defaultMinutes = settings?.defaultMeetingMinutes, defaultMinutes > 0 {
            preCallContext.scheduledDurationMinutes = defaultMinutes
        }
        // Questions pasted under Advanced ("Questions to Ask") join any
        // per-call ones from the form. Both are consumed by the session —
        // stopLive clears them so the next call starts with a fresh list.
        let standing = (UserDefaults.standard.string(forKey: "plannedQuestionsText") ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for q in standing where !preCallContext.plannedQuestions.contains(q) {
            preCallContext.plannedQuestions.append(q)
        }

        // The active rubric tunes the deterministic monitors and defines any
        // custom semantic signals. Missing/invalid rubric = stock behavior.
        let rubric = (try? settings?.loadRubricOrDefault()) ?? .builtInDefault

        // Focus goals: focused signals get modestly more sensitive (merged
        // into the tuning here so the engine stays rubric-agnostic) and win
        // overlay contention below. Both multipliers are boosted — most
        // monitors expose only a cooldown knob, and the semantic coach
        // scales its per-signal cooldowns from the same value.
        focusTypes = FocusGoals.activeTypes()
        var tuning = rubric.builtins
        for type in focusTypes {
            var t = tuning[type.rawValue] ?? SignalTuning()
            t.thresholdMultiplier *= FocusGoals.sensitivityBoost
            t.cooldownMultiplier *= FocusGoals.sensitivityBoost
            tuning[type.rawValue] = t
        }
        // Coaching-note emphasis: signal types the user's saved notes call
        // out get modestly more sensitive — same mechanism as focus goals,
        // gentler boost. The notes themselves also feed the semantic coach
        // as few-shot examples below.
        let noteExamples = TrainingStore.examplesByType()
        for type in TrainingStore.emphasizedTypes() where !focusTypes.contains(type) {
            var t = tuning[type.rawValue] ?? SignalTuning()
            t.thresholdMultiplier *= TrainingStore.sensitivityBoost
            t.cooldownMultiplier *= TrainingStore.sensitivityBoost
            tuning[type.rawValue] = t
        }
        if !noteExamples.isEmpty {
            mclog("[Training] Session tuned by coaching notes: \(noteExamples.keys.sorted().joined(separator: ", "))")
        }
        signalEngine = SignalEngine(
            context: context,
            tuning: tuning,
            languageMode: resolvedLanguage.isEnglish ? .fullEnglish : .multilingualSafe)

        // Tier-2 semantic coaching: progressive enhancement, never a user
        // decision. Runs iff a local model is actually available (or mock
        // mode); a Mac with no model gets the deterministic coach with no
        // toggle and no ritual — but a *degraded* fallback (low memory,
        // engine down) is named in a banner via basicModeNotice, because a
        // silent one reads as "the app is broken" mid-meeting.
        // semanticCoachEnabled survives as an internal kill-switch only
        // (defaults true, no UI).
        // An unchecked model list stays optimistic — the heartbeat degrades
        // gracefully if the engine turns out to be empty.
        // Tier 2 is armed after capture is up — see activateSessionModel.
        // Resolving the model here would read memory before Parakeet and the
        // diarizer load, i.e. before the biggest new tenant of this meeting
        // has arrived, and would have to guess at their cost instead of
        // measuring what is left once they are resident.
        semanticCoach = nil
        nameInference = nil
        // Replacing a session: cancel its activation and free its model before
        // this meeting starts loading one of its own.
        let replaced = sessionModelState
        activationTask?.cancel()
        activationTask = nil
        if replaced != nil {
            Task { [weak self] in await self?.releaseSessionModel(replaced) }
        }
        let sessionID = UUID()
        currentSessionID = sessionID
        sessionModelState = .preparing(sessionID)
        basicModeNotice = nil
        pendingCoachSetup = (tuning, rubric.customSemanticSignals, noteExamples)

        // Kept for the auto-recap on Stop — every session should end with
        // a summary without anyone pressing a button.
        lastSettings = settings
        lastOllamaManager = ollamaManager

        resetSessionState()
        sessionLanguage = resolvedLanguage
        // Exactly one named pre-call participant → they're provisionally
        // the far side; more (or none) and we never guess.
        let participantNames = preCallContext.participants
            .map { $0.name.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        preCallRemoteName = participantNames.count == 1 ? participantNames[0] : nil
        recomputeRemoteAlias()
        status = resolvedLanguage.isEnglish
            ? "Starting — coaching loaded"
            : "Starting — multilingual coaching loaded"
        isLive = true

        let manager = AudioCaptureManager(language: resolvedLanguage)
        // One vocabulary list serves both engines: canonical terms bias
        // SFSpeech recognition; the normalizer repairs the output where the
        // engine takes no hints (Parakeet). Custom terms come from the
        // transcript's "Fix a misheard term" flow and Settings → General.
        let vocabulary = VocabularyNormalizer(
            customText: UserDefaults.standard.string(forKey: "customVocabularyText") ?? "",
            foldVietnameseArtifacts: resolvedLanguage.shouldFoldVietnameseArtifacts)
        manager.contextualHints = context.vocabularyHints + vocabulary.canonicals
        manager.vocabulary = vocabulary
        captureManager = manager

        manager.onUtterance = { [weak self] utterance in
            guard let self else { return }
            self.insertUtterance(utterance)
            mclog("[VM] utterance #\(self.utterances.count): [\(utterance.speaker)] \(utterance.text.prefix(60))")
            // Evaluate on each new utterance for immediate talk-time detection
            self.runSignalEvaluation()
        }

        manager.onPartialText = { [weak self] speaker, text in
            guard let self else { return }
            if text.isEmpty {
                self.livePartials.removeValue(forKey: speaker)
            } else {
                self.livePartials[speaker] = text
            }
        }

        manager.onSpeakerSegments = { [weak self] channel, segments in
            self?.applyDiarization(segments, channel: channel)
        }

        manager.onStatus = { [weak self] msg in
            guard let self, self.nudges.isEmpty else { return }
            self.status = msg
        }

        manager.onSystemAudioLost = { [weak self] in
            // Flip live state too (isMicOnly was sampled once at start) so
            // the arbiter regains mic-only's unlimited end veto.
            self?.micOnly = true
        }

        captureStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await manager.start()
            } catch {
                guard self.currentSessionID == sessionID, self.isLive,
                      !Task.isCancelled else {
                    manager.stop()
                    return
                }
                self.error = error.localizedDescription
                self.status = "Failed"
                self.isLive = false
                self.captureStartTask = nil
                return
            }
            guard self.currentSessionID == sessionID, self.isLive,
                  !Task.isCancelled else {
                manager.stop()
                return
            }
            self.captureStartTask = nil
            micOnly = manager.isMicOnly
            appleCallCapture = manager.isAppleCall
            usedFallbackEngine = manager.transcriptionEngine == .sfSpeech
            startSignalTick()
            sessionStartDate = manager.startTime
            startTimer(from: manager.startTime)
            startSilenceCheck()
            // Capture (and with it Parakeet + the diarizer) is resident now,
            // so free memory finally reflects this meeting's real baseline.
            activationTask = Task { [weak self] in
                await self?.activateSessionModel(sessionID: sessionID,
                                                 settings: settings,
                                                 ollamaManager: ollamaManager)
            }
        }
    }

    /// Settle this meeting's model, after capture is up and against real free
    /// memory. Runs exactly once per session and ends in `.deterministic` or
    /// `.pinned` — never back in `.preparing`.
    ///
    /// The preload is the authority, not an optimisation: it is the only step
    /// that knows whether the model actually loaded. A failed preload steps
    /// down to the next smaller installed rung and tries again; only when
    /// every candidate is exhausted — or the model is missing, size unknown,
    /// memory short, engine down — does the session settle deterministic, and
    /// no coach object is created. Nothing may cold-load a model later; a
    /// heartbeat pulling multiple gigabytes in at minute one is the freeze
    /// this exists to stop.
    ///
    /// Every continuation after an await re-checks the session UUID, because
    /// Stop or a replacing session can land in any of these gaps.
    private func activateSessionModel(sessionID: UUID,
                                      settings: SettingsViewModel?,
                                      ollamaManager: OllamaManager?) async {
        let setup = pendingCoachSetup
        pendingCoachSetup = nil

        func stillCurrent() -> Bool { currentSessionID == sessionID && !Task.isCancelled }

        func settleDeterministic(_ reason: String, notice: BasicModeNotice? = nil) {
            guard stillCurrent() else { return }
            sessionModelState = .deterministic(sessionID)
            semanticCoach = nil
            nameInference = nil
            basicModeNotice = notice
            mclog("[Session] Deterministic coaching — \(reason)")
        }

        guard stillCurrent() else { return }
        guard let setup, let settings, let ollamaManager else {
            return settleDeterministic("no engine or settings")
        }
        // Sample-coach mode never builds a real coach or touches an LLM.
        guard !settings.useMock else { return settleDeterministic("sample-coach mode") }
        guard settings.semanticCoachEnabled else {
            return settleDeterministic("semantic coaching disabled")
        }

        // The ladder can only step down to something installed, so the list
        // has to be current before memory is even consulted.
        await settings.refreshModels()
        guard stillCurrent() else { return }

        guard let availableGB = Self.availableMemoryGB() else {
            return settleDeterministic("free memory unreadable")
        }
        let candidates = ModelMemory.candidatesForCurrentMemory(
            chosen: settings.effectiveModel,
            installed: settings.availableModels,
            availableGB: availableGB)
        guard !candidates.isEmpty else {
            return settleDeterministic(
                String(format: "%.1f GB free fits nothing installed", availableGB),
                notice: .init(
                    cause: "low memory",
                    detail: String(format: "Only %.0f GB of memory is free — no installed AI model fits. Close some apps and restart the session for full coaching.",
                                   availableGB),
                    lowMemory: true))
        }

        guard await ollamaManager.ensureRunning() else {
            return settleDeterministic(
                "engine unavailable",
                notice: .init(cause: "AI engine unavailable",
                              detail: "The local AI engine didn't start, so this session uses built-in signals only."))
        }
        guard stillCurrent() else { return }

        // The heuristic is a snapshot and the OOM verdict is the engine's:
        // when a preload fails, step down to the next smaller installed rung
        // instead of giving up. Still all at session start — no candidate is
        // ever cold-loaded mid-meeting.
        var pinned: String?
        var lastError = ""
        for candidate in candidates {
            if let error = await Self.preloadModel(candidate) {
                lastError = "preload of \(candidate) failed: \(error)"
                mclog("[Session] \(lastError)\(candidate == candidates.last ? "" : " — trying smaller")")
                guard stillCurrent() else { return }
                continue
            }
            pinned = candidate
            break
        }
        guard let candidate = pinned else {
            return settleDeterministic(
                lastError,
                notice: .init(cause: "low memory",
                              detail: "No installed AI model could load into memory. Close some apps and restart the session for full coaching.",
                              lowMemory: true))
        }
        // The preload landed but the meeting moved on underneath it. Free the
        // runner rather than leaving it for a session that no longer exists.
        guard stillCurrent() else {
            await Self.unloadModel(candidate)
            mclog("[Session] Discarded \(candidate) — session ended during preload")
            return
        }

        sessionModelState = .pinned(sessionID, candidate)
        semanticCoach = SemanticCoach(model: candidate,
                                      tuning: setup.tuning,
                                      customSignals: setup.customSignals,
                                      noteExamples: setup.noteExamples)
        // Same engine, separate cadence: propose real names for diarized
        // speakers from transcript evidence ("thanks Sarah").
        nameInference = SpeakerNameInference(model: candidate)
        startSemanticHeartbeat(ollamaManager: ollamaManager)
        mclog("[Session] Pinned \(candidate)")
    }

    /// The one place a session's model is released. Called from every exit:
    /// the normal recap, a failed activation, an empty session, cancellation
    /// at Stop, and a session replaced by a new one. Safe to call with a
    /// state that never pinned anything.
    private func releaseSessionModel(_ state: SessionModelState?) async {
        guard let model = state?.pinnedModel else { return }
        await Self.unloadModel(model)
        mclog("[Session] Released \(model)")
    }

    func stopLive() {
        isLive = false
        // Invalidate the session before anything else: an activation still
        // mid-refresh or mid-preload checks this on its next continuation and
        // stands down instead of pinning a model for a meeting that ended.
        currentSessionID = nil
        activationTask?.cancel()
        activationTask = nil
        captureStartTask?.cancel()
        captureStartTask = nil
        sessionEngineLabel = captureManager?.engineLabel
        captureManager?.stop()
        // Kept (not nil'd into oblivion) so a rename from the post-session
        // view can still reach the diarizers' collected voice clips.
        endedCaptureManager = captureManager
        captureManager = nil
        demoTask?.cancel()
        demoTask = nil
        signalTickTask?.cancel()
        signalTickTask = nil
        semanticTask?.cancel()
        semanticTask = nil
        semanticCoach = nil
        nameInference = nil
        timerTask?.cancel()
        timerTask = nil
        silenceCheckTask?.cancel()
        silenceCheckTask = nil
        dismissTask?.cancel()
        dismissTask = nil
        showSilenceWarning = false
        // Commit whatever the recognizers were still holding: clearing the
        // partials outright dropped the final words before Stop from the
        // transcript and the saved session — and left a short session's
        // pane looking empty (nothing committed yet -> empty state).
        for (speaker, text) in livePartials
        where !text.trimmingCharacters(in: .whitespaces).isEmpty {
            insertUtterance(Utterance(t: elapsedTime, speaker: speaker,
                                      text: text, endT: elapsedTime))
        }
        livePartials = [:]
        // The transcript pane renders TURNS, and turns only rebuild during
        // live evaluation — so words committed since the last tick (plus
        // the partials just flushed) vanished from view the instant the
        // session stopped. Coalesce the full record once before it freezes.
        if !utterances.isEmpty {
            var builder = TurnBuilder()
            builder.rebuild(utterances)
            turns = builder.turns
        }
        status = "Stopped"

        // Demo sessions leave no trace: no save, no threshold adaptation.
        if isDemo {
            status = "Demo stopped"
            let ended = sessionModelState
            sessionModelState = nil
            Task { [weak self] in await self?.releaseSessionModel(ended) }
            return
        }

        // Process feedback to adapt thresholds for next session
        AdaptiveThresholds.processSessionFeedback(nudges)

        saveSession()

        // Counts toward the give-to-a-friend prompt (fires after the 2nd
        // real meeting). Same emptiness guard as the transcript itself —
        // a mis-click session with no words isn't a meeting.
        if !utterances.isEmpty {
            ReferralInvites.completedMeetingCount += 1
        }

        // Questions are per-meeting: coverage was just written into the
        // session file, so clear both sources — the live checklist context
        // and the standing paste under Advanced — for a fresh list next
        // call. Goal/participants stay as the last-used context.
        preCallContext.plannedQuestions = []
        UserDefaults.standard.removeObject(forKey: "plannedQuestionsText")

        showPostSession = true

        // Auto-recap: every session ends with a summary, no button. The
        // no-model path gets the instant deterministic review inside
        // generateReview, so this never blocks on an engine.
        if let settings = lastSettings, let ollamaManager = lastOllamaManager {
            generateReview(ollamaManager: ollamaManager, settings: settings)
        } else {
            // No recap will run, so nothing else will free the model.
            let ended = sessionModelState
            sessionModelState = nil
            Task { [weak self] in await self?.releaseSessionModel(ended) }
        }
    }

    // MARK: - Demo replay

    /// Replay the bundled sample meeting through the real signal pipeline at
    /// several times real speed — no mic, no permissions, no downloads. The
    /// nudge feed, overlay, and transcript behave exactly as in a live
    /// session; scripted "AI" nudges are injected at fixed timestamps.
    /// Default pacing compresses the whole script into ~15 seconds.
    func startDemo(speed: Double? = nil) {
        guard !isLive, let script = DemoScript.loadBundled() else { return }
        let speed = speed ?? max(1, script.duration / 15)

        preCallContext = PreCallContext()   // neutral context → general type
        signalEngine = SignalEngine(context: preCallContext)
        semanticCoach = nil
        nameInference = nil
        focusTypes = []   // demo choreography must not depend on user goals

        resetSessionState()
        savedPath = nil
        showPostSession = false
        isDemo = true
        isLive = true
        status = "Demo — replaying a sample meeting"

        demoTask = Task { @MainActor [weak self] in
            var pendingNudges = script.scriptedNudges
            var index = 0
            var clock: TimeInterval = 0

            while !Task.isCancelled {
                guard let self, self.isLive else { return }
                let nextUtterance = index < script.utterances.count
                    ? script.utterances[index].t : .infinity
                let nextNudge = pendingNudges.first?.t ?? .infinity
                let next = min(nextUtterance, nextNudge)
                guard next.isFinite else { break }

                try? await Task.sleep(for: .seconds(max(0, next - clock) / speed))
                guard !Task.isCancelled, self.isLive else { return }
                clock = next
                self.elapsedTime = clock

                if nextNudge <= nextUtterance {
                    let scripted = pendingNudges.removeFirst()
                    if let nudge = scripted.nudge {
                        self.nudges.append(nudge)
                        self.setActiveNudge(nudge)
                        mclog("[Demo] scripted nudge: \(nudge.type.rawValue)")
                    }
                } else {
                    self.insertUtterance(script.utterances[index])
                    index += 1
                    self.runSignalEvaluation()
                }
            }

            guard !Task.isCancelled, let self, self.isLive else { return }
            // Let the last moment land, then wrap with the instant review.
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, self.isLive else { return }
            self.elapsedTime = script.duration
            self.finishDemo()
        }
    }

    private func finishDemo() {
        isLive = false
        demoTask = nil
        status = "Demo finished — a real session looks just like this"
        meetingReview = instantReview(durationMinutes: max(1, Int(elapsedTime / 60)))
    }

    func deleteSession() {
        if let path = savedPath {
            try? FileManager.default.removeItem(atPath: path)
            savedPath = nil
        }
        resetSessionState()
        showPostSession = false
        status = ""
    }

    /// Clear all per-session UI state. Shared by live start, demo start,
    /// and delete — a new per-session field must reset here, in one place.
    private func resetSessionState() {
        utterances = []
        turns = []
        livePartials = [:]
        speakerNameSuggestions = []
        rejectedNameSuggestions = []
        channelLabels = [:]
        baseLabelRenames = [:]
        segmentRenames = [:]
        remoteAlias = nil
        latestRemoteLabels = []
        preCallRemoteName = nil
        endedCaptureManager = nil
        micOnly = false
        appleCallCapture = false
        usedFallbackEngine = false
        sessionLanguage = nil
        sessionStartDate = nil
        nudges = []
        activeNudge = nil
        talkStats.reset()
        error = nil
        meetingReview = nil
        askedPlannedQuestions = []
        manuallyUncheckedQuestions = []
        elapsedTime = 0
        backoff = NudgeBackoff()
    }

    func dismissPostSession() {
        showPostSession = false
    }

    /// Relabel one channel's utterances with its diarized speakers —
    /// "Meeting" → "Speaker 1/2/…" (mic-only), "Them" → "Them 1/2/…"
    /// (system audio), or enrolled/renamed real names. Segments arrive
    /// incrementally and can refine earlier calls, so every pass re-derives
    /// labels for the whole diarizable history of that channel.
    ///
    /// Utterances that clearly span MORE than one diarized speaker are
    /// split at the segment boundaries — a single dominant label for a
    /// back-and-forth exchange hands every word to one person, which was
    /// the main source of attribution errors (measured ~12% of words).
    private func applyDiarization(_ segments: [SpeakerSegment], channel: DiarizationChannel) {
        // Remap stale labels from publishes that raced a rename.
        let segments = segments.map { seg in
            segmentRenames[seg.speaker].map {
                SpeakerSegment(speaker: $0, start: seg.start, end: seg.end)
            } ?? seg
        }
        // Track every label this channel has ever produced (including
        // renames) — a relabeled utterance must stay eligible for the
        // refined segments of later passes.
        for s in segments { channelLabels[channel, default: []].insert(s.speaker) }
        let owned = channelLabels[channel] ?? []

        // Keep the latest full publish as fallback evidence. Once labels have
        // actually claimed transcript utterances, recomputeRemoteAlias uses
        // those instead — a stray audio-only slot must not make a 1:1 look
        // like a group call and leave short acknowledgements as raw "Them".
        if channel == .system {
            latestRemoteLabels = Set(segments.map(\.speaker))
        }

        // Each utterance only needs the segments that can overlap it. Both
        // lists are time-sorted, so a binary-searched window replaces the
        // full-array scans that made this pass O(utterances × segments) —
        // it runs on the main thread on every publish of a long call.
        let maxSegDur = segments.reduce(0.0) { max($0, $1.end - $1.start) }

        var changed = false
        var rebuilt: [Utterance] = []
        rebuilt.reserveCapacity(utterances.count)
        for u in utterances {
            guard belongsToChannel(u.speaker, channel: channel, owned: owned) else {
                rebuilt.append(u)
                continue
            }
            let window = Self.overlapWindow(for: u, in: segments, maxDur: maxSegDur)
            if let parts = Self.splitByDiarization(u, segments: window) {
                rebuilt.append(contentsOf: parts)
                changed = true
                continue
            }
            if let label = Self.dominantSpeaker(for: u, in: window), label != u.speaker {
                var copy = u
                copy.speaker = label
                rebuilt.append(copy)
                changed = true
            } else {
                rebuilt.append(u)
            }
        }
        if changed { utterances = rebuilt }
        if channel == .system { recomputeRemoteAlias() }
        guard changed else { return }
        if var engine = signalEngine {
            engine.invalidateTurnCache()
            signalEngine = engine
        }
        runSignalEvaluation()
    }

    /// Whether an utterance's current label came from this channel: the
    /// channel's base label, its slot-label form, or anything the channel's
    /// diarizer has published (enrolled names, renames).
    private func belongsToChannel(_ speaker: String, channel: DiarizationChannel,
                                  owned: Set<String>) -> Bool {
        switch channel {
        case .mic:
            return speaker == "Meeting" || speaker.hasPrefix("Speaker ")
                || owned.contains(speaker) || baseLabelRenames["Meeting"] == speaker
        case .system:
            return speaker == "Them" || speaker.hasPrefix("Them ")
                || owned.contains(speaker) || baseLabelRenames["Them"] == speaker
        }
    }

    // MARK: - Speaker naming

    /// Rename a diarized speaker ("Them 2", "Speaker 1", or a wrong name)
    /// everywhere: transcript history, live diarizer timeline (future turns),
    /// and the voice-profile store (future sessions recognize the voice).
    func renameSpeaker(_ label: String, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != label else { return }

        // Transcript relabels immediately — the diarizer republish path
        // also covers this, but only while live, and up to a second later.
        var changed = false
        for i in utterances.indices where utterances[i].speaker == label {
            utterances[i].speaker = name
            changed = true
        }
        if changed {
            var builder = TurnBuilder()
            builder.rebuild(utterances)
            turns = builder.turns
            if var engine = signalEngine {
                engine.invalidateTurnCache()
                signalEngine = engine
            }
        }
        // Keep the rename eligible for later diarization refinements.
        for (channel, labels) in channelLabels where labels.contains(label) {
            channelLabels[channel]?.insert(name)
        }
        // "Them"/"Meeting" was never diarized (single far speaker, or model
        // still downloading) — remember the mapping so later utterances of
        // that base label keep the name without a diarizer in the loop.
        if label == "Them" || label == "Meeting" {
            baseLabelRenames[label] = name
        }
        baseLabelRenames = baseLabelRenames.mapValues { $0 == label ? name : $0 }
        // Chain: A→B then B→C must leave A mapping to C.
        segmentRenames = segmentRenames.mapValues { $0 == label ? name : $0 }
        segmentRenames[label] = name

        // Live timeline + voice profile. The manager survives stopLive()
        // precisely so a post-session rename can still reach the clips.
        (captureManager ?? endedCaptureManager)?.renameSpeaker(label, to: name)

        // The name is remembered the moment it's given — a too-short voice
        // clip must not lose the person from participant memory. Demo
        // renames leave no trace, like everything else about the demo.
        if !isDemo {
            ParticipantStore.remember(name: name)
            UserDefaults.standard.set(true, forKey: "hasSeenSpeakerNamingHint")
        }
        latestRemoteLabels = Set(latestRemoteLabels.map { $0 == label ? name : $0 })
        recomputeRemoteAlias()
        // Renaming from the post-session view: the file on disk still says
        // the old label — rewrite it or the name is gone on reopen.
        if !isLive {
            rewriteSavedTranscript()
        }

        speakerNameSuggestions.removeAll { $0.label == label }
        mclog("[VM] Renamed speaker \(label) → \(name)")
    }

    // MARK: - One-on-one remote alias (display layer)

    /// The label a speaker should DISPLAY as. Aliases "Them"-family labels
    /// to the sole remote participant's name in a dual-channel one-on-one;
    /// everything else passes through. Stored labels stay raw — turns,
    /// partials, and saved-file serialization all resolve through here so
    /// the whole surface agrees.
    func displaySpeaker(_ label: String) -> String {
        guard let alias = remoteAlias,
              label == "Them" || label.hasPrefix("Them ") else { return label }
        return alias
    }

    /// Sole-remote-name resolution, strongest evidence first: labels that
    /// actually own transcript utterances, then the latest diarizer publish,
    /// then an explicit base-label rename and the single pre-call participant.
    ///
    /// Transcript evidence outranks the raw diarizer count because LS-EEND can
    /// emit a short false speaker segment in an otherwise clean 1:1. That slot
    /// should not disable the known person's alias unless it claims words in
    /// the transcript. Once two labels do claim words, this immediately drops
    /// the alias and preserves honest group-call attribution.
    private func recomputeRemoteAlias() {
        let owned = channelLabels[.system] ?? []
        let transcriptLabels = Set(utterances.lazy.compactMap { utterance -> String? in
            let label = utterance.speaker
            guard label != "Them",
                  label.hasPrefix("Them ") || owned.contains(label)
                    || self.baseLabelRenames["Them"] == label else { return nil }
            return label
        })
        let evidence = transcriptLabels.isEmpty ? latestRemoteLabels : transcriptLabels

        if evidence.count >= 2 {
            remoteAlias = nil
        } else if let only = evidence.first,
                  only != "Them", !only.hasPrefix("Them ") {
            remoteAlias = only
        } else if latestRemoteLabels.count >= 2 {
            // Transcript attribution hasn't separated the voices yet, but the
            // diarizer clearly hears more than one — never fall through to the
            // rename/pre-call guesses on what is likely a group call.
            remoteAlias = nil
        } else if let renamed = baseLabelRenames["Them"] {
            remoteAlias = renamed
        } else {
            remoteAlias = preCallRemoteName
        }
    }

    /// Post-session rename: atomically replace only the saved file's
    /// `## Transcript` section with freshly serialized turns. Title, notes,
    /// nudges, and any review the LLM already wrote stay byte-identical.
    private func rewriteSavedTranscript() {
        guard let path = savedPath,
              let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var lines = content.components(separatedBy: "\n")
        guard let heading = lines.firstIndex(of: "## Transcript") else { return }
        let body = lines.index(after: heading)
        let end = lines[body...].firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
        lines.replaceSubrange(body..<end, with: serializedTranscriptLines() + [""])
        try? lines.joined(separator: "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        mclog("[VM] Rewrote saved transcript after rename: \(path)")
    }

    /// The saved file's transcript body: coalesced turns with the display
    /// alias applied BEFORE coalescing, so "Them" and "Them 1" fragments of
    /// the same person merge into one line under their real name.
    private func serializedTranscriptLines() -> [String] {
        var resolved = utterances
        for i in resolved.indices {
            resolved[i].speaker = displaySpeaker(resolved[i].speaker)
        }
        var builder = TurnBuilder()
        builder.rebuild(resolved)
        return builder.turns.map { "- [\($0.formattedTime)] \($0.speaker): \($0.text)" }
    }

    /// Accept an LLM name suggestion — routes through the full rename path.
    func confirmNameSuggestion(_ suggestion: SpeakerNameSuggestion) {
        renameSpeaker(suggestion.label, to: suggestion.name)
    }

    /// "Fix a misheard term" from a transcript row: persist the correction
    /// into the custom vocabulary (every future session repairs it), rewrite
    /// the current transcript in place so the fix lands instantly, and hand
    /// the running capture pipeline the updated normalizer so the rest of
    /// THIS call comes out right too.
    func fixMisheardTerm(wrote rawWrote: String, canonical rawCanonical: String) {
        let wrote = rawWrote.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\n", with: " ")
        // "=" is the vocabulary line separator — it can't appear in a term.
        let canonical = rawCanonical.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "=", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !wrote.isEmpty, !canonical.isEmpty, wrote.lowercased() != canonical.lowercased()
        else { return }

        let key = "customVocabularyText"
        let existing = UserDefaults.standard.string(forKey: key) ?? ""
        let line = "\(canonical) = \(wrote)"
        UserDefaults.standard.set(existing.isEmpty ? line : existing + "\n" + line, forKey: key)

        let foldVietnamese = sessionLanguage?.shouldFoldVietnameseArtifacts ?? true
        let fixer = VocabularyNormalizer(
            customText: line, foldVietnameseArtifacts: foldVietnamese)
        var changed = false
        for i in utterances.indices {
            let fixed = fixer.normalize(utterances[i].text)
            if fixed != utterances[i].text {
                utterances[i] = Utterance(t: utterances[i].t, speaker: utterances[i].speaker,
                                          text: fixed, endT: utterances[i].endT)
                changed = true
            }
        }
        if changed {
            var builder = TurnBuilder()
            builder.rebuild(utterances)
            turns = builder.turns
            if var engine = signalEngine {
                engine.invalidateTurnCache()
                signalEngine = engine
            }
        }
        captureManager?.vocabulary = VocabularyNormalizer(
            customText: UserDefaults.standard.string(forKey: key) ?? "",
            foldVietnameseArtifacts: foldVietnamese)
        mclog("[VM] Vocabulary fix: \"\(wrote)\" → \"\(canonical)\" (rewrote \(changed ? "transcript" : "nothing"))")
    }

    func dismissNameSuggestion(_ suggestion: SpeakerNameSuggestion) {
        rejectedNameSuggestions.insert(suggestion.key)
        speakerNameSuggestions.removeAll { $0.key == suggestion.key }
    }

    /// Split an utterance across diarized speaker spans when at least two
    /// speakers each held a meaningful share of it. Words are allocated
    /// proportionally by span duration (the recognizer gives no word
    /// timestamps). Returns nil when the utterance is effectively
    /// single-speaker — the dominant-label path handles it.
    /// The segments that can overlap `u`: start ≥ u.t − longest segment
    /// (anything earlier must end before u starts) and start < u.endT.
    private static func overlapWindow(for u: Utterance, in segments: [SpeakerSegment],
                                      maxDur: TimeInterval) -> ArraySlice<SpeakerSegment> {
        func lowerBound(_ key: TimeInterval) -> Int {
            var lo = 0, hi = segments.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if segments[mid].start < key { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        return segments[lowerBound(u.t - maxDur)..<lowerBound(u.endT)]
    }

    private static func splitByDiarization(_ u: Utterance,
                                           segments: ArraySlice<SpeakerSegment>) -> [Utterance]? {
        guard u.duration > 1.5 else { return nil }
        // Overlapping spans in time order, merging near-adjacent same-speaker runs.
        var spans: [(speaker: String, start: TimeInterval, end: TimeInterval)] = []
        // Segments arrive sorted from SpeakerDiarizer.publish — re-sorting
        // here per utterance was O(n·m·log m) across a session for nothing.
        for seg in segments {
            let s = max(u.t, seg.start), e = min(u.endT, seg.end)
            guard e - s > 0.2 else { continue }
            if let last = spans.last, last.speaker == seg.speaker, s - last.end < 0.5 {
                spans[spans.count - 1].end = max(last.end, e)
            } else {
                spans.append((seg.speaker, s, e))
            }
        }
        let minPart = max(0.7, u.duration * 0.15)
        let strong = spans.filter { $0.end - $0.start >= minPart }
        guard Set(strong.map(\.speaker)).count >= 2 else { return nil }

        let words = u.text.split(separator: " ")
        guard words.count >= 4 else { return nil }
        let total = strong.reduce(0.0) { $0 + ($1.end - $1.start) }
        var parts: [Utterance] = []
        var idx = 0
        for (i, span) in strong.enumerated() {
            let isLast = i == strong.count - 1
            let share = (span.end - span.start) / total
            let take = isLast ? words.count - idx
                : min(words.count - idx, max(1, Int((Double(words.count) * share).rounded())))
            guard take > 0 else { continue }
            let text = words[idx..<(idx + take)].joined(separator: " ")
            parts.append(Utterance(t: span.start, speaker: span.speaker,
                                   text: text, endT: span.end))
            idx += take
        }
        guard parts.count >= 2, idx >= words.count else { return nil }
        return parts
    }

    /// The speaker whose segments overlap this utterance the most.
    /// Requires meaningful overlap (>0.3s or >30% of the utterance).
    private static func dominantSpeaker(for u: Utterance, in segments: ArraySlice<SpeakerSegment>) -> String? {
        var overlapBySpeaker: [String: TimeInterval] = [:]
        for seg in segments {
            let overlap = min(u.endT, seg.end) - max(u.t, seg.start)
            if overlap > 0 {
                overlapBySpeaker[seg.speaker, default: 0] += overlap
            }
        }
        guard let best = overlapBySpeaker.max(by: { $0.value < $1.value }) else { return nil }
        let needed = min(0.3, max(0.1, u.duration * 0.3))
        return best.value >= needed ? best.key : nil
    }

    /// Insert keeping chronological order — the You and Them pipelines emit
    /// independently, so arrivals can be slightly out of order.
    private func insertUtterance(_ u: Utterance) {
        var u = u
        // A renamed base label sticks to new arrivals; diarization (when
        // running) still refines them into individual speakers later.
        if let mapped = baseLabelRenames[u.speaker] {
            u.speaker = mapped
        }
        if let last = utterances.last, u.t < last.t {
            let idx = utterances.lastIndex(where: { $0.t <= u.t })
                .map { utterances.index(after: $0) } ?? 0
            utterances.insert(u, at: idx)
        } else {
            utterances.append(u)
        }
    }

    // MARK: - Feedback

    func recordFeedback(nudgeId: UUID, feedback: NudgeFeedback) {
        if let i = nudges.firstIndex(where: { $0.id == nudgeId }) {
            nudges[i].feedback = feedback
            // Explicit feedback (overlay or post-hoc feed buttons)
            // overrides an earlier machine-observed ignore.
            nudges[i].wasIgnored = nil
        }
        backoff.userInteracted()
        if activeNudge?.id == nudgeId {
            dismissActiveNudge()
        }
        // Also update in engine's allNudges
        if var engine = signalEngine {
            engine.recordFeedback(nudgeId: nudgeId, feedback: feedback)
            signalEngine = engine
        }
    }

    // MARK: - Post-call review

    func generateReview(ollamaManager: OllamaManager, settings: SettingsViewModel) {
        guard !utterances.isEmpty else {
            // An empty session still holds whatever it pinned.
            let ended = sessionModelState
            sessionModelState = nil
            Task { [weak self] in await self?.releaseSessionModel(ended) }
            return
        }
        isGeneratingSummary = true
        meetingReview = nil

        let durationMin = max(1, Int(elapsedTime) / 60)

        // Demo sessions never reach the LLM: reviewing a scripted meeting as
        // if it were real would be the user's first review experience.
        // Mock mode and known-empty model lists get the instant review too,
        // instead of spinning up an engine that has nothing to run.
        if isDemo || settings.useMock ||
            (settings.hasCheckedModels && settings.ollamaReachable && settings.availableModels.isEmpty) {
            let ended = sessionModelState
            sessionModelState = nil
            finishReview(instantReview(durationMinutes: durationMin))
            Task { [weak self] in await self?.releaseSessionModel(ended) }
            return
        }

        // Only a model this session actually pinned may be used. A session
        // still `preparing` never settled, and a `deterministic` one settled
        // against loading anything — neither gets to fall back to the current
        // preference here, where the heaviest call of the workflow would run
        // at the tightest moment for memory.
        guard case .pinned(_, let reviewModel) = sessionModelState else {
            mclog("[Review] session never pinned a model — instant review only")
            let ended = sessionModelState
            sessionModelState = nil
            finishReview(instantReview(durationMinutes: durationMin))
            Task { [weak self] in await self?.releaseSessionModel(ended) }
            return
        }

        // Speaker-labeled TURNS, not raw utterances — the review has to
        // attribute commitments and positions, which needs who-said-what,
        // and the far side commits in 1-3 word fragments that read as
        // noise line-by-line. Coalescing gives the model whole thoughts.
        var reviewTurns = TurnBuilder()
        reviewTurns.rebuild(utterances)
        let labeledTranscript = reviewTurns.turns
            .map { "\($0.speaker): \($0.text)" }
            .joined(separator: "\n")

        let (system, user) = PromptBuilder.buildPostCallReviewPrompt(
            nudges: nudges,
            transcript: labeledTranscript,
            context: preCallContext,
            durationMinutes: durationMin,
            languageName: sessionLanguage?.englishName
        )

        if ollamaManager.status == .stopped {
            ollamaManager.start()
        }

        Task {
            // Wait for Ollama to be ready before sending the request
            if ollamaManager.status != .running {
                for _ in 1...30 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if ollamaManager.status == .running { break }
                    if case .error = ollamaManager.status { break }
                }
            }

            var summary: String?
            if ollamaManager.status == .running {
                // Engine is up — but a fresh install may have no models (the
                // earlier check couldn't reach it); skip the doomed request
                // instead of waiting out a model-not-found error.
                await settings.refreshModels()
                if !settings.availableModels.isEmpty {
                    do {
                        summary = try await Self.completeReview(reviewModel, system, user)
                    } catch {
                        // The LLM path failed (engine died, timeout) — the
                        // instant review is still better than an error string.
                        mclog("[Review] LLM review failed, using instant review: \(error.localizedDescription)")
                    }
                }
            }
            if let summary {
                finishReview(MeetingReview.parse(llmText: summary,
                                                 talkShare: talkStats.sessionShare))
            } else {
                finishReview(instantReview(durationMinutes: durationMin))
            }
            // The recap was the model's last job — give the multi-GB of
            // KV/compute memory back instead of letting keep_alive hold it.
            // Skipped when another meeting already started: that session owns
            // its own model now, and this one's was already released when it
            // replaced this session.
            if !isLive {
                let ended = sessionModelState
                sessionModelState = nil
                await releaseSessionModel(ended)
            }
        }
    }

    /// Single epilogue for every review path: publish, stop the spinner,
    /// and persist into the session file.
    private func finishReview(_ review: MeetingReview) {
        meetingReview = review
        isGeneratingSummary = false
        persistReview()
        // The review's title names the meeting from full understanding —
        // adopt it over the word-frequency heuristic (never over a human).
        if let title = review.title, let path = savedPath {
            TranscriptSearch.adoptGeneratedTitle(title, for: URL(fileURLWithPath: path))
        }
    }

    /// Toggle one Suggested Next Step's checkbox and persist immediately —
    /// checked state survives restarts as "- [x]" task lines in the file.
    func toggleActionItem(_ id: UUID) {
        guard var review = meetingReview,
              let i = review.actionItems.firstIndex(where: { $0.id == id }) else { return }
        review.actionItems[i].isDone.toggle()
        meetingReview = review
        persistReview()
    }

    /// Write the review into the saved session file under "## Review" so
    /// trends and the rubric advisor can mine it later. Replaces any earlier
    /// review section — reviews can be regenerated (and checkbox toggles
    /// re-persist through the same path).
    private func persistReview() {
        guard let path = savedPath, let review = meetingReview,
              var content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        if let range = content.range(of: "\n## Review") {
            content = String(content[..<range.lowerBound])
        }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        content += "\n\n## Review\n\n\(review.recapMarkdown)\n"
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func instantReview(durationMinutes: Int) -> MeetingReview {
        DeterministicReview.review(nudges: nudges,
                                   utterances: utterances,
                                   context: preCallContext,
                                   durationMinutes: durationMinutes,
                                   talkShare: talkStats.sessionShare)
    }

    // MARK: - Nudge quotes

    /// The transcript moment behind a nudge: the turn active at the nudge's
    /// call-relative timestamp plus the following turn (the exchange).
    /// Pure lookup — works retroactively on nudges from any session.
    func turnsAround(_ timestamp: TimeInterval) -> [Turn] {
        guard !turns.isEmpty else { return [] }
        guard let idx = turns.lastIndex(where: { $0.t <= timestamp }) else {
            return [resolvedForDisplay(turns[0])]
        }
        var result = [resolvedForDisplay(turns[idx])]
        if idx + 1 < turns.count { result.append(resolvedForDisplay(turns[idx + 1])) }
        return result
    }

    /// A copy of the turn carrying its display label — nudge quotes must
    /// agree with the transcript pane's aliased names.
    private func resolvedForDisplay(_ turn: Turn) -> Turn {
        let name = displaySpeaker(turn.speaker)
        guard name != turn.speaker else { return turn }
        return Turn(id: turn.id, speaker: name, isYou: turn.isYou,
                    t: turn.t, endT: turn.endT, text: turn.text,
                    wordCount: turn.wordCount, utteranceCount: turn.utteranceCount)
    }

    // MARK: - Planned questions

    /// Mark planned questions as covered when a "You" turn contains most of
    /// the question's content words. Keyword overlap, not exact match — the
    /// spoken phrasing never matches the typed one.
    /// Manual override from the live checklist: tapping a row toggles it.
    func togglePlannedQuestion(_ index: Int) {
        if askedPlannedQuestions.contains(index) {
            askedPlannedQuestions.remove(index)
            manuallyUncheckedQuestions.insert(index)
        } else {
            askedPlannedQuestions.insert(index)
            manuallyUncheckedQuestions.remove(index)
        }
    }

    private func updatePlannedQuestionCoverage() {
        let questions = preCallContext.plannedQuestions
        guard !questions.isEmpty else { return }
        for (i, question) in questions.enumerated()
        where !askedPlannedQuestions.contains(i) && !manuallyUncheckedQuestions.contains(i) {
            let keywords = Self.questionKeywords(question)
            guard !keywords.isEmpty else { continue }
            for turn in turns where turn.isYou {
                let turnWords = Set(TextAnalysis.words(turn.text))
                let matched = keywords.filter(turnWords.contains).count
                // ≥60% of content words (and at least one) heard in one turn.
                if matched > 0, matched * 10 >= keywords.count * 6 {
                    askedPlannedQuestions.insert(i)
                    mclog("[Questions] Covered planned question #\(i + 1)")
                    break
                }
            }
        }
    }

    /// Content words of a planned question — question scaffolding and
    /// filler stripped so matching keys on the substance.
    static func questionKeywords(_ question: String) -> [String] {
        let stop: Set<String> = [
            "what", "how", "why", "when", "where", "who", "which", "whose",
            "the", "a", "an", "is", "are", "was", "were", "do", "does", "did",
            "you", "your", "yours", "we", "our", "ours", "they", "their",
            "to", "of", "in", "on", "for", "about", "and", "or", "if",
            "it", "its", "that", "this", "these", "those", "there",
            "have", "has", "had", "be", "been", "being", "will", "would",
            "could", "should", "can", "with", "them", "us", "i", "my", "me",
            "get", "got", "any", "some", "at", "as", "by", "from", "up",
        ]
        return TextAnalysis.words(question).filter { $0.count >= 3 && !stop.contains($0) }
    }

    // MARK: - Semantic heartbeat (tier 2)

    private func startSemanticHeartbeat(ollamaManager: OllamaManager) {
        semanticTask = Task { @MainActor [weak self] in
            // Let the meeting build some context before the first pass.
            try? await Task.sleep(for: .seconds(90))

            // Each pass is a full local-LLM prompt eval — the single biggest
            // recurring CPU cost of a session. Two gates keep it honest
            // (field data 2026-08-06: 62 passes over a 72-min call, every
            // one returning zero calls):
            //   - skip when fewer than 3 utterances arrived since the last
            //     pass — the window the model would see barely changed;
            //   - after each empty pass stretch the interval one step
            //     (60→90→120s); any fired nudge snaps it back to 60. A
            //     nudge-worthy moment stays in the 180s window, so the
            //     worst-case extra latency is one stretched beat.
            var analyzedCount = 0
            var interval = SemanticCoach.heartbeatSeconds
            while !Task.isCancelled, let self, self.isLive {
                if ollamaManager.status == .running, let coach = self.semanticCoach,
                   self.utterances.count - analyzedCount >= 3 {
                    analyzedCount = self.utterances.count
                    let newNudges = await coach.analyze(
                        utterances: self.utterances,
                        elapsed: self.elapsedTime,
                        context: self.preCallContext
                    )
                    guard self.isLive else { break }
                    interval = newNudges.isEmpty
                        ? min(interval + 30, 120)
                        : SemanticCoach.heartbeatSeconds
                    for nudge in newNudges {
                        self.nudges.append(nudge)
                        self.setActiveNudge(nudge)
                        mclog("[Semantic] \(nudge.type.rawValue): \(nudge.text)")
                    }
                }
                if ollamaManager.status == .running, let inference = self.nameInference {
                    // Piggybacks the heartbeat; throttles itself and skips
                    // entirely when every speaker is already named.
                    let suggestions = await inference.analyze(
                        utterances: self.utterances,
                        elapsed: self.elapsedTime,
                        rejected: self.rejectedNameSuggestions
                    )
                    guard self.isLive else { break }
                    for s in suggestions
                    where !self.speakerNameSuggestions.contains(where: { $0.label == s.label }) {
                        self.speakerNameSuggestions.append(s)
                        mclog("[Names] Suggesting \(s.label) = \(s.name) (\(s.confidence))")
                    }
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    // MARK: - Signal tick

    private func startSignalTick() {
        signalTickTask = Task { @MainActor [weak self] in
            // Wait for some transcript to accumulate
            try? await Task.sleep(for: .seconds(5))

            while !Task.isCancelled, let self, self.isLive {
                self.runSignalEvaluation()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func runSignalEvaluation() {
        guard var engine = signalEngine, !utterances.isEmpty else { return }

        let newNudges = engine.evaluate(
            utterances: utterances,
            elapsed: elapsedTime,
            context: preCallContext
        )
        turns = engine.turns
        signalEngine = engine
        talkStats.update(turns: turns, elapsed: elapsedTime)
        updatePlannedQuestionCoverage()

        for nudge in newNudges {
            nudges.append(nudge)
            setActiveNudge(nudge)
            mclog("[Signal] \(nudge.type.rawValue): \(nudge.text)")
        }

        if newNudges.isEmpty && activeNudge == nil {
            status = "Listening — \(utterances.count) utterances"
        }
    }

    private func setActiveNudge(_ nudge: Nudge) {
        // Overlay contention: a nudge for the user's focus goal is not
        // replaced by an off-focus one of equal or lower urgency — it still
        // lands in the feed. High-stakes corrections always break through.
        if let current = activeNudge,
           focusTypes.contains(current.type), !focusTypes.contains(nudge.type),
           Self.urgencyRank(nudge.urgency) <= Self.urgencyRank(current.urgency) {
            return
        }
        // Fatigue backoff: after consecutive ignored nudges the overlay
        // goes quiet for a growing gap — the nudge stays feed-only.
        guard backoff.shouldDisplay(urgency: nudge.urgency,
                                    isPositive: nudge.type.isPositive,
                                    isFocusType: focusTypes.contains(nudge.type),
                                    now: elapsedTime) else {
            return
        }
        activeNudge = nudge
        // Auto-dismiss: positives ("green") hold a little longer — praise is
        // the easiest thing to miss while looking at a face on another screen.
        let displaySeconds: Double = nudge.type.isPositive ? 10 : 6
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(displaySeconds))
            guard let self, self.activeNudge?.id == nudge.id else { return }
            // Held the overlay for the full window, untouched — that's an
            // ignore. Displaced nudges never reach here (the id guard).
            if let i = self.nudges.firstIndex(where: { $0.id == nudge.id }),
               self.nudges[i].feedback == nil {
                self.nudges[i].wasIgnored = true
                self.backoff.nudgeIgnored()
            }
            self.dismissActiveNudge()
        }
    }

    private static func urgencyRank(_ urgency: NudgeUrgency) -> Int {
        switch urgency {
        case .low: return 0
        case .med: return 1
        case .high: return 2
        }
    }

    private func dismissActiveNudge() {
        withAnimation(.easeOut(duration: 0.3)) {
            activeNudge = nil
        }
        dismissTask?.cancel()
        dismissTask = nil
    }

    // MARK: - Timer & silence

    private func startTimer(from start: Date) {
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, self.isLive {
                self.elapsedTime = Date().timeIntervalSince(start)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func startSilenceCheck() {
        silenceCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))

            while !Task.isCancelled, let self, self.isLive {
                let lastUtteranceTime = self.utterances.last?.t ?? 0
                let silenceDuration = self.elapsedTime - lastUtteranceTime

                if silenceDuration >= self.silenceThreshold && !self.showSilenceWarning {
                    // Two very different diagnoses share this trigger. A
                    // transcript that flowed and stopped = the room went
                    // quiet ("Meeting ended?"). A transcript that never
                    // really started = WE can't hear — typically a call
                    // whose audio lives on the iPhone or a headset (field
                    // report 2026-08-06: relayed call, "Listening", one
                    // utterance, then blamed the room). Blaming the room
                    // for a capture gap hides the one thing the user could
                    // actually fix.
                    self.silenceLooksLikeCaptureGap = self.utterances.count <= 3
                    self.showSilenceWarning = true
                    mclog("[Silence] No speech for \(Int(silenceDuration))s — showing \(self.silenceLooksLikeCaptureGap ? "capture-gap" : "meeting-ended") warning")
                } else if silenceDuration < self.silenceThreshold && self.showSilenceWarning {
                    self.showSilenceWarning = false
                    mclog("[Silence] Speech resumed — dismissed warning")
                }

                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func dismissSilenceWarning() {
        showSilenceWarning = false
    }

    // MARK: - Save session

    private func saveSession() {
        guard !utterances.isEmpty else { return }

        let dir = AppSupport.sessionsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let filename = "session_\(formatter.string(from: Date())).md"
        let file = dir.appendingPathComponent(filename)

        var lines: [String] = []
        lines.append("# Meeting Coach Session — \(formatter.string(from: Date()))")
        // Title precedence: the real meeting name (from the meeting's
        // window title, via detection) beats the pre-call-derived
        // "person · subject", which beats nothing (the sidebar's transcript
        // heuristic fills that in later). Filename stays date-based — it's
        // the sort key and is parsed for the session date.
        if let title = meetingTitleProvider?() ?? Self.sessionTitle(context: preCallContext) {
            lines.append("**Title:** \(title)")
        }
        lines.append("**Duration:** \(elapsedFormatted)")
        lines.append("**Utterances:** \(utterances.count)")
        lines.append("**Nudges:** \(nudges.count)")
        lines.append("**Engine:** \(sessionEngineLabel ?? "unknown")")
        if let sessionLanguage {
            lines.append("**Language:** \(sessionLanguage.code)")
        }
        if let share = talkStats.sessionShare {
            lines.append("**Talk ratio:** \(Int(share * 100))% you")
        }
        lines.append("")

        // Pre-call context
        if !preCallContext.meetingGoal.isEmpty {
            lines.append("## Pre-Call Context")
            lines.append("**Goal:** \(preCallContext.meetingGoal)")
            if preCallContext.scheduledDurationMinutes > 0 {
                lines.append("**Scheduled Duration:** \(preCallContext.scheduledDurationMinutes) min")
            }
            if !preCallContext.participants.isEmpty {
                lines.append("**Participants:** \(preCallContext.participants.map { "\($0.name) (\($0.role))" }.joined(separator: ", "))")
            }
            if !preCallContext.myKnownTendencies.isEmpty {
                lines.append("**Known Tendencies:** \(preCallContext.myKnownTendencies.joined(separator: ", "))")
            }
            lines.append("")
        }

        // Planned questions with coverage — checked = heard in a You turn.
        if !preCallContext.plannedQuestions.isEmpty {
            lines.append("## Planned Questions")
            for (i, q) in preCallContext.plannedQuestions.enumerated() {
                lines.append("- [\(askedPlannedQuestions.contains(i) ? "x" : " ")] \(q)")
            }
            lines.append("")
        }

        // Transcript — coalesced turns, not raw utterances. The far side
        // commits in small fragments ("Can you hear" / "me?") and a saved
        // file full of 1-3 word lines is unreadable next to any other
        // tool's export. Turns keep one timestamp per thought; the pane
        // renders the same shape.
        lines.append("## Transcript")
        lines.append(contentsOf: serializedTranscriptLines())
        lines.append("")

        // Nudges
        if !nudges.isEmpty {
            lines.append("## Nudges")
            for n in nudges {
                // Mutually exclusive suffixes: explicit feedback wins over
                // the machine-observed ignore marker.
                let feedbackStr = n.feedback.map { " | feedback: \($0.rawValue)" }
                    ?? (n.wasIgnored == true ? " | ignored" : "")
                lines.append("- [\(n.formattedTime)] **\(n.typeKey)** (\(n.urgency.rawValue)): \(n.text)\(feedbackStr)")
            }
            lines.append("")
        }

        let content = lines.joined(separator: "\n")
        try? content.write(to: file, atomically: true, encoding: .utf8)
        savedPath = file.path
        status = "Session saved to \(dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))/"
    }

    /// "Chris · close the deal" from pre-call context (first named
    /// participant + goal); nil when there's no context to name it by.
    static func sessionTitle(context: PreCallContext) -> String? {
        let person = context.participants
            .map { $0.name.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        var subject = context.meetingGoal
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if subject.count > 48 { subject = String(subject.prefix(45)) + "…" }
        let parts = [person, subject.isEmpty ? nil : subject].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
