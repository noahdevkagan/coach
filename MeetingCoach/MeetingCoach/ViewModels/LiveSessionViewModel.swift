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

    // Tier-2 semantic coaching (local LLM heartbeat)
    private var semanticCoach: SemanticCoach?
    private var semanticTask: Task<Void, Never>?

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
        signalEngine = SignalEngine(context: context)

        // Tier-2 semantic coaching: local LLM heartbeat (optional, toggleable)
        if let settings, let ollamaManager, settings.semanticCoachEnabled {
            semanticCoach = SemanticCoach(model: settings.selectedModel)
            if ollamaManager.status == .stopped {
                ollamaManager.start()
            }
            startSemanticHeartbeat(ollamaManager: ollamaManager)
        } else {
            semanticCoach = nil
        }

        utterances = []
        turns = []
        livePartials = [:]
        nudges = []
        activeNudge = nil
        talkStats.reset()
        error = nil
        status = "Starting — 10 coaching signals loaded"
        elapsedTime = 0
        meetingSummary = nil
        isLive = true

        let manager = AudioCaptureManager()
        manager.contextualHints = context.vocabularyHints
        captureManager = manager
        let sessionStart = Date()

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
    func startDemo(speed: Double = 7) {
        guard !isLive, let script = DemoScript.loadBundled() else { return }

        preCallContext = PreCallContext()   // neutral context → general type
        signalEngine = SignalEngine(context: preCallContext)
        semanticCoach = nil

        utterances = []
        turns = []
        livePartials = [:]
        nudges = []
        activeNudge = nil
        talkStats.reset()
        error = nil
        meetingSummary = nil
        savedPath = nil
        showPostSession = false
        elapsedTime = 0
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
        utterances = []
        turns = []
        nudges = []
        activeNudge = nil
        talkStats.reset()
        meetingSummary = nil
        showPostSession = false
        status = ""
    }

    func dismissPostSession() {
        showPostSession = false
    }

    /// Relabel mixed-stream ("Meeting") utterances with diarized speakers.
    /// Segments arrive incrementally and can refine earlier calls, so every
    /// pass re-derives labels for the whole diarizable history.
    private func applyDiarization(_ segments: [SpeakerSegment]) {
        var changed = false
        for i in utterances.indices {
            let current = utterances[i].speaker
            guard current == "Meeting" || current.hasPrefix("Speaker ") else { continue }
            guard let label = Self.dominantSpeaker(
                for: utterances[i], in: segments), label != current else { continue }
            utterances[i].speaker = label
            changed = true
        }
        guard changed else { return }
        if var engine = signalEngine {
            engine.invalidateTurnCache()
            signalEngine = engine
        }
        runSignalEvaluation()
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
        }
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

        // No model installed (or mock mode): render the instant on-device
        // review instead of spinning up an engine that has nothing to run.
        if settings.useMock ||
            (settings.hasCheckedModels && settings.ollamaReachable && settings.availableModels.isEmpty) {
            meetingSummary = instantReview(durationMinutes: durationMin)
            isGeneratingSummary = false
            persistReview()
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

            guard ollamaManager.status == .running else {
                meetingSummary = instantReview(durationMinutes: durationMin)
                isGeneratingSummary = false
                persistReview()
                return
            }

            let client = OllamaClient(model: model)
            do {
                let result = try await client.complete(system: system, user: user)
                meetingSummary = result
            } catch {
                // The LLM path failed (no model pulled, engine died) — the
                // instant review is still better than an error string.
                mclog("[Review] LLM review failed, using instant review: \(error.localizedDescription)")
                meetingSummary = instantReview(durationMinutes: durationMin)
            }
            isGeneratingSummary = false
            persistReview()
        }
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
                                     durationMinutes: durationMinutes)
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
        activeNudge = nudge
        // Auto-dismiss after 6 seconds
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.activeNudge?.id == nudge.id else { return }
            self.dismissActiveNudge()
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

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/MeetingCoach")
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
                let feedbackStr = n.feedback.map { " | feedback: \($0.rawValue)" } ?? ""
                lines.append("- [\(n.formattedTime)] **\(n.type.rawValue)** (\(n.urgency.rawValue)): \(n.text)\(feedbackStr)")
            }
            lines.append("")
        }

        let content = lines.joined(separator: "\n")
        try? content.write(to: file, atomically: true, encoding: .utf8)
        savedPath = file.path
        status = "Session saved to ~/Documents/MeetingCoach/"
    }
}
