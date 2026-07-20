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

    /// End-of-meeting summary
    var meetingSummary: String?
    var isGeneratingSummary = false
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
    private var silenceCheckTask: Task<Void, Never>?
    private let silenceThreshold: TimeInterval = 180  // 3 minutes

    private var captureManager: AudioCaptureManager?
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

    /// Signal types sharpened by the active focus goals (set per session).
    private var focusTypes: Set<NudgeType> = []

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
        preCallContext = context

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
        signalEngine = SignalEngine(context: context, tuning: tuning)

        // Tier-2 semantic coaching: local LLM heartbeat (optional, toggleable)
        if let settings, let ollamaManager, settings.semanticCoachEnabled {
            semanticCoach = SemanticCoach(model: settings.selectedModel,
                                          tuning: tuning,
                                          customSignals: rubric.customSemanticSignals,
                                          noteExamples: noteExamples)
            if ollamaManager.status == .stopped {
                ollamaManager.start()
            }
            startSemanticHeartbeat(ollamaManager: ollamaManager)
        } else {
            semanticCoach = nil
        }

        resetSessionState()
        status = "Starting — 10 coaching signals loaded"
        isLive = true

        let manager = AudioCaptureManager()
        manager.contextualHints = context.vocabularyHints
        captureManager = manager
        let sessionStart = Date()
        sessionStartDate = sessionStart

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

        manager.onSpeakerSegments = { [weak self] segments in
            self?.applyDiarization(segments)
        }

        manager.onStatus = { [weak self] msg in
            guard let self, self.nudges.isEmpty else { return }
            self.status = msg
        }

        Task {
            do {
                try await manager.start()
            } catch {
                self.error = error.localizedDescription
                self.status = "Failed"
                self.isLive = false
                return
            }
            micOnly = manager.isMicOnly
            startSignalTick()
            startTimer(from: sessionStart)
            startSilenceCheck()
        }
    }

    func stopLive() {
        isLive = false
        captureManager?.stop()
        captureManager = nil
        demoTask?.cancel()
        demoTask = nil
        signalTickTask?.cancel()
        signalTickTask = nil
        semanticTask?.cancel()
        semanticTask = nil
        semanticCoach = nil
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
        status = "Stopped"

        // Demo sessions leave no trace: no save, no threshold adaptation.
        if isDemo {
            status = "Demo stopped"
            return
        }

        // Process feedback to adapt thresholds for next session
        AdaptiveThresholds.processSessionFeedback(nudges)

        saveSession()
        showPostSession = true
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
        meetingSummary = instantReview(durationMinutes: max(1, Int(elapsedTime / 60)))
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
        micOnly = false
        sessionStartDate = nil
        nudges = []
        activeNudge = nil
        talkStats.reset()
        error = nil
        meetingSummary = nil
        elapsedTime = 0
        backoff = NudgeBackoff()
    }

    func dismissPostSession() {
        showPostSession = false
    }

    /// Relabel mixed-stream ("Meeting") utterances with diarized speakers.
    /// Segments arrive incrementally and can refine earlier calls, so every
    /// pass re-derives labels for the whole diarizable history.
    ///
    /// Utterances that clearly span MORE than one diarized speaker are
    /// split at the segment boundaries — a single dominant label for a
    /// back-and-forth exchange hands every word to one person, which was
    /// the main source of attribution errors (measured ~12% of words).
    private func applyDiarization(_ segments: [SpeakerSegment]) {
        var changed = false
        var rebuilt: [Utterance] = []
        rebuilt.reserveCapacity(utterances.count)
        for u in utterances {
            guard u.speaker == "Meeting" || u.speaker.hasPrefix("Speaker ") else {
                rebuilt.append(u)
                continue
            }
            if let parts = Self.splitByDiarization(u, segments: segments) {
                rebuilt.append(contentsOf: parts)
                changed = true
                continue
            }
            if let label = Self.dominantSpeaker(for: u, in: segments), label != u.speaker {
                var copy = u
                copy.speaker = label
                rebuilt.append(copy)
                changed = true
            } else {
                rebuilt.append(u)
            }
        }
        guard changed else { return }
        utterances = rebuilt
        if var engine = signalEngine {
            engine.invalidateTurnCache()
            signalEngine = engine
        }
        runSignalEvaluation()
    }

    /// Split an utterance across diarized speaker spans when at least two
    /// speakers each held a meaningful share of it. Words are allocated
    /// proportionally by span duration (the recognizer gives no word
    /// timestamps). Returns nil when the utterance is effectively
    /// single-speaker — the dominant-label path handles it.
    private static func splitByDiarization(_ u: Utterance,
                                           segments: [SpeakerSegment]) -> [Utterance]? {
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
    private static func dominantSpeaker(for u: Utterance, in segments: [SpeakerSegment]) -> String? {
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
        guard !utterances.isEmpty else { return }
        isGeneratingSummary = true
        meetingSummary = nil

        let durationMin = max(1, Int(elapsedTime) / 60)

        // Demo sessions never reach the LLM: reviewing a scripted meeting as
        // if it were real would be the user's first review experience.
        // Mock mode and known-empty model lists get the instant review too,
        // instead of spinning up an engine that has nothing to run.
        if isDemo || settings.useMock ||
            (settings.hasCheckedModels && settings.ollamaReachable && settings.availableModels.isEmpty) {
            finishReview(instantReview(durationMinutes: durationMin))
            return
        }

        let (system, user) = PromptBuilder.buildPostCallReviewPrompt(
            nudges: nudges,
            transcript: fullTranscript,
            context: preCallContext,
            durationMinutes: durationMin
        )

        let model = settings.selectedModel
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
                        summary = try await OllamaClient(model: model).complete(system: system, user: user)
                    } catch {
                        // The LLM path failed (engine died, timeout) — the
                        // instant review is still better than an error string.
                        mclog("[Review] LLM review failed, using instant review: \(error.localizedDescription)")
                    }
                }
            }
            finishReview(summary ?? instantReview(durationMinutes: durationMin))
        }
    }

    /// Single epilogue for every review path: publish, stop the spinner,
    /// and persist into the session file.
    private func finishReview(_ summary: String) {
        meetingSummary = summary
        isGeneratingSummary = false
        persistReview()
    }

    /// Write the review into the saved session file under "## Review" so
    /// trends and the rubric advisor can mine it later. Replaces any earlier
    /// review section — reviews can be regenerated.
    private func persistReview() {
        guard let path = savedPath, let summary = meetingSummary,
              var content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        if let range = content.range(of: "\n## Review") {
            content = String(content[..<range.lowerBound])
        }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        content += "\n\n## Review\n\n\(summary)\n"
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func instantReview(durationMinutes: Int) -> String {
        DeterministicReview.generate(nudges: nudges,
                                     utterances: utterances,
                                     context: preCallContext,
                                     durationMinutes: durationMinutes,
                                     talkShare: talkStats.sessionShare)
    }

    // MARK: - Semantic heartbeat (tier 2)

    private func startSemanticHeartbeat(ollamaManager: OllamaManager) {
        semanticTask = Task { @MainActor [weak self] in
            // Let the meeting build some context before the first pass.
            try? await Task.sleep(for: .seconds(90))

            while !Task.isCancelled, let self, self.isLive {
                if ollamaManager.status == .running, let coach = self.semanticCoach {
                    let newNudges = await coach.analyze(
                        utterances: self.utterances,
                        elapsed: self.elapsedTime,
                        context: self.preCallContext
                    )
                    guard self.isLive else { break }
                    for nudge in newNudges {
                        self.nudges.append(nudge)
                        self.setActiveNudge(nudge)
                        mclog("[Semantic] \(nudge.type.rawValue): \(nudge.text)")
                    }
                }
                try? await Task.sleep(for: .seconds(SemanticCoach.heartbeatSeconds))
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
        // Auto-dismiss after 6 seconds
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
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
                    self.showSilenceWarning = true
                    mclog("[Silence] No speech for \(Int(silenceDuration))s — showing warning")
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
        lines.append("**Duration:** \(elapsedFormatted)")
        lines.append("**Utterances:** \(utterances.count)")
        lines.append("**Nudges:** \(nudges.count)")
        if let share = talkStats.sessionShare {
            lines.append("**Talk ratio:** \(Int(share * 100))% you")
        }
        lines.append("")

        // Pre-call context
        if !preCallContext.meetingGoal.isEmpty {
            lines.append("## Pre-Call Context")
            lines.append("**Goal:** \(preCallContext.meetingGoal)")
            lines.append("**Scheduled Duration:** \(preCallContext.scheduledDurationMinutes) min")
            if !preCallContext.participants.isEmpty {
                lines.append("**Participants:** \(preCallContext.participants.map { "\($0.name) (\($0.role))" }.joined(separator: ", "))")
            }
            if !preCallContext.myKnownTendencies.isEmpty {
                lines.append("**Known Tendencies:** \(preCallContext.myKnownTendencies.joined(separator: ", "))")
            }
            lines.append("")
        }

        // Transcript
        lines.append("## Transcript")
        for u in utterances {
            let mm = Int(u.t) / 60
            let ss = Int(u.t) % 60
            lines.append("- [\(String(format: "%02d:%02d", mm, ss))] \(u.speaker): \(u.text)")
        }
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
}
