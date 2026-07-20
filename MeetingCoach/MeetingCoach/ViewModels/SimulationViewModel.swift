import Foundation
import SwiftUI

/// Backs the transcript-drop pane: load a saved transcript for display and
/// collect coaching-feedback notes as training examples. (The old in-app
/// "run the coach over this transcript" simulation was removed — nothing in
/// the UI triggered it; offline replay lives in bench/.)
@MainActor @Observable
final class SimulationViewModel {
    var calls: [CoachingCall] = []
    var isRunning = false
    var currentTime: TimeInterval = 0
    var error: String?
    var utterances: [Utterance] = []
    var transcriptFileName: String?

    /// The transcript window currently being analyzed by the LLM
    var currentWindow: [Utterance] = []
    var isAnalyzing = false

    /// Coaching feedback / notes to save as training data
    var feedbackText: String = ""
    var feedbackSaved = false

    /// V2 deterministic nudges
    var v2Nudges: [Nudge] = []
    var isV2Mode = false

    var meetingDuration: String {
        guard let last = utterances.last else { return "--:--" }
        return mmss(last.t)
    }

    func loadTranscript(from url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            utterances = TranscriptParser.parse(text)
            transcriptFileName = url.lastPathComponent
            error = nil
            calls = []
            currentWindow = []
            currentTime = 0
            // Preserve feedbackText — user may have coaching notes they want to keep
            feedbackSaved = false
            v2Nudges = []
            isV2Mode = false
        } catch {
            self.error = "Could not read file: \(error.localizedDescription)"
        }
    }
}
