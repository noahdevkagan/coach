import Foundation

/// A saved training example: a transcript window paired with the expected coaching signals.
struct TrainingExample: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    let date: Date
    /// A short excerpt of the transcript (first ~500 words)
    let transcriptExcerpt: String
    /// The raw coaching feedback the user pasted
    let feedback: String
    /// Parsed signal examples extracted from the feedback
    let signals: [SignalExample]
}

struct SignalExample: Codable, Sendable {
    let signalId: String
    let evidence: String
    let nudge: String
}

/// Reads/writes training examples to ~/Library/Application Support/MeetingCoach/
enum TrainingStore {

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MeetingCoach")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("training_examples.json")
    }

    static func load() -> [TrainingExample] {
        guard let data = try? Data(contentsOf: fileURL),
              let examples = try? JSONDecoder().decode([TrainingExample].self, from: data) else {
            return []
        }
        mclog("[Training] Loaded \(examples.count) training examples")
        return examples
    }

    static func save(_ examples: [TrainingExample]) {
        guard let data = try? JSONEncoder().encode(examples) else { return }
        try? data.write(to: fileURL, options: .atomic)
        mclog("[Training] Saved \(examples.count) training examples to \(fileURL.path)")
    }

    static func append(_ example: TrainingExample) {
        var all = load()
        all.append(example)
        save(all)
    }

    /// Parse raw coaching feedback text into signal examples.
    /// Supports formats like:
    ///   "Trigger 1: repetition_loop" / "Signal: repetition_loop"
    ///   "Evidence: ..."
    ///   "Nudge: ..."
    static func parseFeedback(_ text: String) -> [SignalExample] {
        var results: [SignalExample] = []
        let lines = text.components(separatedBy: .newlines)

        var currentSignal: String?
        var currentEvidence: String?
        var currentNudge: String?

        let signalIds = [
            "repetition_loop", "escalation_rising", "resolution_capture",
            "unaddressed_objection", "stacked_asks", "global_negative",
            "talk_time_imbalance", "promise_vs_clock", "positive_reinforcement"
        ]

        func flush() {
            if let sig = currentSignal {
                results.append(SignalExample(
                    signalId: sig,
                    evidence: currentEvidence ?? "",
                    nudge: currentNudge ?? ""
                ))
            }
            currentSignal = nil
            currentEvidence = nil
            currentNudge = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            // Check if line contains a signal ID
            if let found = signalIds.first(where: { lower.contains($0) }) {
                flush()
                currentSignal = found
                continue
            }

            // Check for "Trigger N:" pattern followed by a name
            if lower.hasPrefix("trigger") && lower.contains(":") {
                // Try to find signal name after the colon
                let afterColon = trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                if let found = signalIds.first(where: { afterColon.lowercased().contains($0) }) {
                    flush()
                    currentSignal = found
                }
                continue
            }

            // Evidence line
            if lower.hasPrefix("evidence") || lower.hasPrefix("quote") || lower.hasPrefix("example") {
                let value = extractValue(trimmed)
                if !value.isEmpty { currentEvidence = value }
                continue
            }

            // Nudge line
            if lower.hasPrefix("nudge") || lower.hasPrefix("coaching") || lower.hasPrefix("action") || lower.hasPrefix("suggestion") {
                let value = extractValue(trimmed)
                if !value.isEmpty { currentNudge = value }
                continue
            }

            // If we have a current signal and this looks like content, append to evidence
            if currentSignal != nil && currentEvidence == nil && !trimmed.isEmpty
                && !lower.hasPrefix("#") && !lower.hasPrefix("---") {
                currentEvidence = trimmed
            }
        }
        flush()

        return results
    }

    private static func extractValue(_ line: String) -> String {
        // Split on first ":" and take the rest
        guard let colonIndex = line.firstIndex(of: ":") else { return line }
        let after = line[line.index(after: colonIndex)...]
        return after.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}
