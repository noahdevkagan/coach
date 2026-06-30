import Foundation
import SwiftUI

@MainActor @Observable
final class SimulationViewModel {
    var calls: [CoachingCall] = []
    var isRunning = false
    var progress: Double = 0
    var currentTime: TimeInterval = 0
    var error: String?
    var utterances: [Utterance] = []
    var transcriptFileName: String?
    var triggerCount: Int = 0
    var triggersSkipped: Int = 0

    /// The transcript window currently being analyzed by the LLM
    var currentWindow: [Utterance] = []
    var isAnalyzing = false

    /// Coaching feedback / notes to save as training data
    var feedbackText: String = ""
    var feedbackSaved = false

    /// V2 deterministic nudges
    var v2Nudges: [Nudge] = []
    var isV2Mode = false

    private var simulationTask: Task<Void, Never>?

    var meetingDuration: String {
        guard let last = utterances.last else { return "--:--" }
        let mm = Int(last.t) / 60
        let ss = Int(last.t) % 60
        return String(format: "%02d:%02d", mm, ss)
    }

    var statusText: String {
        if !isRunning { return "" }
        if isV2Mode {
            return "V2 signals: \(v2Nudges.count) nudges"
        }
        return "Analyzed \(triggerCount) moments (skipped \(triggersSkipped))"
    }

    func loadTranscript(from url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            utterances = TranscriptParser.parse(text)
            transcriptFileName = url.lastPathComponent
            error = nil
            calls = []
            currentWindow = []
            progress = 0
            currentTime = 0
            triggerCount = 0
            triggersSkipped = 0
            feedbackText = ""
            feedbackSaved = false
            v2Nudges = []
            isV2Mode = false
        } catch {
            self.error = "Could not read file: \(error.localizedDescription)"
        }
    }

    // MARK: - V2 Deterministic Simulation

    func runV2(context: PreCallContext) {
        guard !utterances.isEmpty else {
            error = "No transcript loaded"
            return
        }

        isRunning = true
        isV2Mode = true
        v2Nudges = []
        calls = []
        error = nil
        progress = 0
        triggerCount = 0

        let totalDuration = (utterances.last?.t ?? 0) - (utterances.first?.t ?? 0)
        let startTime = utterances.first?.t ?? 0

        simulationTask = Task { @MainActor in
            var engine = SignalEngine(context: context)

            // Walk through utterances chronologically, evaluating at each one
            for (i, utterance) in utterances.enumerated() {
                guard !Task.isCancelled else { break }

                let elapsed = utterance.t - startTime
                currentTime = utterance.t
                progress = totalDuration > 0 ? elapsed / totalDuration : 1
                currentWindow = [utterance]

                let upToNow = Array(utterances.prefix(i + 1))
                let newNudges = engine.evaluate(
                    utterances: upToNow,
                    elapsed: elapsed,
                    context: context
                )

                for nudge in newNudges {
                    v2Nudges.append(nudge)
                    triggerCount += 1
                }
            }

            isRunning = false
            isAnalyzing = false
            progress = 1
        }
    }

    // MARK: - Legacy LLM Simulation

    func run(settings: SettingsViewModel) {
        guard !utterances.isEmpty else {
            error = "No transcript loaded"
            return
        }

        let rubric: Rubric
        do {
            rubric = try settings.loadRubricOrDefault()
        } catch {
            self.error = "Could not load rubric: \(error.localizedDescription)"
            return
        }

        isRunning = true
        isV2Mode = false
        calls = []
        currentWindow = []
        error = nil
        progress = 0
        triggerCount = 0
        triggersSkipped = 0

        let client = OllamaClient(model: settings.selectedModel)
        let coach = CoachEngine(rubric: rubric, client: client, useMock: settings.useMock)
        let totalDuration = (utterances.last?.t ?? 0) - (utterances.first?.t ?? 0)

        // Throttle: only send a trigger to the LLM every minInterval seconds.
        let minInterval: TimeInterval = settings.useMock ? 0 : 90

        simulationTask = Task { @MainActor in
            var lastProcessedTime: TimeInterval = -999

            for await trigger in simulate(utterances: utterances, rubric: rubric) {
                guard !Task.isCancelled else { break }

                currentTime = trigger.now
                progress = totalDuration > 0 ? trigger.now / totalDuration : 1

                let elapsed = trigger.now - lastProcessedTime
                if elapsed < minInterval {
                    triggersSkipped += 1
                    continue
                }

                currentWindow = trigger.window
                isAnalyzing = true
                triggerCount += 1

                do {
                    let newCalls = try await coach.onTrigger(trigger)
                    calls.append(contentsOf: newCalls)
                    lastProcessedTime = trigger.now
                    isAnalyzing = false
                } catch {
                    self.error = "LLM error: \(error.localizedDescription)"
                    isAnalyzing = false
                    break
                }
            }
            isRunning = false
            isAnalyzing = false
            progress = 1
        }
    }

    func stop() {
        simulationTask?.cancel()
        isRunning = false
        isAnalyzing = false
    }

    /// Save the transcript + coaching feedback as a training example.
    func saveTrainingFeedback() {
        guard !feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let excerpt = utterances.prefix(80)
            .map { "[\($0.formattedTime)] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")

        let signals = TrainingStore.parseFeedback(feedbackText)

        let example = TrainingExample(
            date: Date(),
            transcriptExcerpt: String(excerpt.prefix(3000)),
            feedback: feedbackText,
            signals: signals
        )

        TrainingStore.append(example)
        feedbackSaved = true
        mclog("[Training] Saved example with \(signals.count) parsed signals from feedback")
    }
}
