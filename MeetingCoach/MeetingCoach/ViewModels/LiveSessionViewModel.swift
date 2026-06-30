import Foundation
import SwiftUI

/// Manages a live coaching session: audio capture → transcription → deterministic signals → nudges.
@MainActor @Observable
final class LiveSessionViewModel {
    var isLive = false
    var utterances: [Utterance] = []
    var nudges: [Nudge] = []
    var activeNudge: Nudge?
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

    /// Silence detection — nudge user to stop if meeting seems over
    var showSilenceWarning = false
    private var silenceCheckTask: Task<Void, Never>?
    private let silenceThreshold: TimeInterval = 180  // 3 minutes

    private var captureManager: AudioCaptureManager?
    private var signalTickTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var signalEngine: SignalEngine?
    private var dismissTask: Task<Void, Never>?

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

    func startLive(context: PreCallContext) {
        guard !isLive else { return }

        preCallContext = context
        signalEngine = SignalEngine(context: context)

        utterances = []
        nudges = []
        activeNudge = nil
        error = nil
        status = "Starting — 3 deterministic signals loaded"
        elapsedTime = 0
        meetingSummary = nil
        isLive = true

        let manager = AudioCaptureManager()
        captureManager = manager
        let sessionStart = Date()

        manager.onUtterance = { [weak self] utterance in
            guard let self else { return }
            self.utterances.append(utterance)
            mclog("[VM] utterance #\(self.utterances.count): \(utterance.text.prefix(60))")
            // Evaluate on each new utterance for immediate talk-time detection
            self.runSignalEvaluation()
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
        signalTickTask?.cancel()
        signalTickTask = nil
        timerTask?.cancel()
        timerTask = nil
        silenceCheckTask?.cancel()
        silenceCheckTask = nil
        dismissTask?.cancel()
        dismissTask = nil
        showSilenceWarning = false
        status = "Stopped"

        saveSession()
        showPostSession = true
    }

    func deleteSession() {
        if let path = savedPath {
            try? FileManager.default.removeItem(atPath: path)
            savedPath = nil
        }
        utterances = []
        nudges = []
        activeNudge = nil
        meetingSummary = nil
        showPostSession = false
        status = ""
    }

    func dismissPostSession() {
        showPostSession = false
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
                meetingSummary = "Could not generate review: Ollama is not running"
                isGeneratingSummary = false
                return
            }

            let client = OllamaClient(model: model)
            do {
                let result = try await client.complete(system: system, user: user)
                meetingSummary = result
            } catch {
                meetingSummary = "Could not generate review: \(error.localizedDescription)"
            }
            isGeneratingSummary = false
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
        signalEngine = engine

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
