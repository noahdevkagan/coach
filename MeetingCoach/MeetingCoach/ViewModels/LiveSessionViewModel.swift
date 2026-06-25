import Foundation
import SwiftUI

/// Manages a live coaching session: audio capture → transcription → triggers → coaching calls.
@MainActor @Observable
final class LiveSessionViewModel {
    var isLive = false
    var utterances: [Utterance] = []
    var calls: [CoachingCall] = []
    var error: String?
    var status: String = ""
    var triggerCount = 0
    var elapsedTime: TimeInterval = 0

    /// Signal feed — shows every evaluation + signals so the panel feels alive
    var signalFeed: [SignalFeedItem] = []
    var isAnalyzing = false
    var analyzeWordCount = 0

    /// End-of-meeting summary
    var meetingSummary: String?
    var isGeneratingSummary = false
    var savedPath: String?
    var showPostSession = false

    /// Silence detection — nudge user to stop if meeting seems over
    var showSilenceWarning = false
    private var silenceCheckTask: Task<Void, Never>?
    private let silenceThreshold: TimeInterval = 180  // 3 minutes

    private var captureManager: AudioCaptureManager?
    private var heartbeatTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var client: OllamaClient?
    private var coach: CoachEngine?
    private var rubric: Rubric?
    private let minInterval: TimeInterval = 15

    var elapsedFormatted: String {
        let mm = Int(elapsedTime) / 60
        let ss = Int(elapsedTime) % 60
        return String(format: "%02d:%02d", mm, ss)
    }

    var hasSession: Bool {
        !calls.isEmpty || !utterances.isEmpty
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

    func startLive(settings: SettingsViewModel) {
        guard !isLive else { return }

        let r: Rubric
        do {
            r = try settings.loadRubricOrDefault()
        } catch {
            self.error = "Could not load rubric: \(error.localizedDescription)"
            return
        }
        rubric = r

        print("[Session] Rubric '\(r.name)' loaded with \(r.signals.count) signals: \(r.signals.map(\.id))")

        if r.signals.isEmpty {
            self.error = "Rubric has 0 signals — check \(settings.rubricPath)"
            return
        }

        let c = OllamaClient(model: settings.selectedModel)
        client = c
        coach = CoachEngine(rubric: r, client: c, useMock: settings.useMock)

        utterances = []
        calls = []
        signalFeed = []
        isAnalyzing = false
        error = nil
        status = "Starting — \(r.signals.count) signals loaded"
        triggerCount = 0
        elapsedTime = 0
        meetingSummary = nil
        isLive = true

        let manager = AudioCaptureManager()
        captureManager = manager
        let sessionStart = Date() // same time base as AudioCaptureManager.startTime

        manager.onUtterance = { [weak self] utterance in
            guard let self else { return }
            self.utterances.append(utterance)
            mclog("[VM] utterance #\(self.utterances.count): \(utterance.text.prefix(60))")
        }

        manager.onStatus = { [weak self] msg in
            // Only show audio status before first trigger fires
            guard let self, self.triggerCount == 0 else { return }
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
            startHeartbeat()
            startTimer(from: sessionStart)
            startSilenceCheck()
        }
    }

    func stopLive() {
        isLive = false
        captureManager?.stop()
        captureManager = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        timerTask?.cancel()
        timerTask = nil
        silenceCheckTask?.cancel()
        silenceCheckTask = nil
        showSilenceWarning = false
        status = "Stopped"

        saveSession()
        showPostSession = true

        if !utterances.isEmpty {
            generateSummary()
        }
    }

    func deleteSession() {
        // Remove saved file
        if let path = savedPath {
            try? FileManager.default.removeItem(atPath: path)
            savedPath = nil
        }
        // Clear all session data
        utterances = []
        calls = []
        signalFeed = []
        meetingSummary = nil
        showPostSession = false
        status = ""
    }

    func dismissPostSession() {
        showPostSession = false
    }

    func generateSummary() {
        guard let client, !utterances.isEmpty else { return }
        isGeneratingSummary = true
        meetingSummary = nil

        let durationMin = max(1, Int(elapsedTime) / 60)
        let (system, user) = PromptBuilder.buildSummaryPrompt(calls: calls, transcript: fullTranscript, durationMinutes: durationMin)

        Task {
            do {
                let result = try await client.complete(system: system, user: user)
                meetingSummary = result
            } catch {
                meetingSummary = "Could not generate summary: \(error.localizedDescription)"
            }
            isGeneratingSummary = false
        }
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
        lines.append("**Coaching Calls:** \(calls.count)")
        lines.append("")

        // Transcript
        lines.append("## Transcript")
        for u in utterances {
            let mm = Int(u.t) / 60
            let ss = Int(u.t) % 60
            lines.append("- [\(String(format: "%02d:%02d", mm, ss))] \(u.speaker): \(u.text)")
        }
        lines.append("")

        // Coaching calls
        if !calls.isEmpty {
            lines.append("## Coaching Signals")
            for c in calls {
                lines.append("### [\(c.formattedTime)] \(c.signalId)")
                lines.append("**Evidence:** \(c.evidence)")
                lines.append("**Nudge:** \(c.nudge)")
                lines.append("")
            }
        }

        let content = lines.joined(separator: "\n")
        try? content.write(to: file, atomically: true, encoding: .utf8)
        savedPath = file.path
        status = "Session saved to ~/Documents/MeetingCoach/"
    }

    // MARK: - Heartbeat trigger

    private func startHeartbeat() {
        heartbeatTask = Task { @MainActor [weak self] in
            // Wait for some transcript to accumulate
            try? await Task.sleep(for: .seconds(8))

            while !Task.isCancelled, let self, self.isLive {
                await self.fireTrigger()
                try? await Task.sleep(for: .seconds(self.minInterval))
            }
        }
    }

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
            // Don't check in the first minute
            try? await Task.sleep(for: .seconds(60))

            while !Task.isCancelled, let self, self.isLive {
                let lastUtteranceTime = self.utterances.last?.t ?? 0
                let silenceDuration = self.elapsedTime - lastUtteranceTime

                if silenceDuration >= self.silenceThreshold && !self.showSilenceWarning {
                    self.showSilenceWarning = true
                    mclog("[Silence] No speech for \(Int(silenceDuration))s — showing warning")
                } else if silenceDuration < self.silenceThreshold && self.showSilenceWarning {
                    // Speech resumed — dismiss warning
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

    private func fireTrigger() async {
        guard let rubric, let coach, !utterances.isEmpty else {
            mclog("[Trigger] Skipped: rubric=\(rubric != nil) coach=\(coach != nil) utterances=\(utterances.count)")
            return
        }

        let now = elapsedTime
        let winSecs = Double(rubric.window.transcriptSeconds)

        let windowAll = utterances.filter { now - winSecs <= $0.t && $0.t <= now }
        let window = Array(windowAll.suffix(50))
        guard !window.isEmpty else { return }

        let older = utterances.filter { $0.t < now - winSecs }
        let summary = older.isEmpty ? "(meeting just started)" :
            older.suffix(4).map { "- [\($0.formattedTime)] \($0.speaker): \($0.text)" }
                .joined(separator: "\n")

        let trigger = Trigger(reason: .heartbeat, now: now, window: window, summary: summary)
        triggerCount += 1
        let wordCount = window.reduce(0) { $0 + $1.text.split(separator: " ").count }

        isAnalyzing = true
        analyzeWordCount = wordCount
        status = "Analyzing \(wordCount) words..."
        NSLog("[Trigger] #%d: %d utterances, %d in window, %d words", triggerCount, utterances.count, window.count, wordCount)

        do {
            let newCalls = try await coach.onTrigger(trigger)
            isAnalyzing = false
            calls.append(contentsOf: newCalls)

            if newCalls.isEmpty {
                signalFeed.append(SignalFeedItem(t: now, message: "No patterns in \(wordCount) words"))
                status = "Scan \(triggerCount) done — no signals"
            } else {
                for call in newCalls {
                    signalFeed.append(SignalFeedItem(t: now, message: call.signalId, call: call))
                }
                status = "Scan \(triggerCount) — \(newCalls.count) signal(s)!"
            }
        } catch {
            isAnalyzing = false
            signalFeed.append(SignalFeedItem(t: now, message: "Error: \(error.localizedDescription)"))
            status = "Scan \(triggerCount) — error"
            self.error = "LLM: \(error.localizedDescription)"
        }
    }
}
