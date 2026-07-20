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

    /// Aliases → canonical NudgeType raw value. Keys are normalized
    /// (lowercase, alphanumerics and single spaces). Multi-word aliases and
    /// distinctive tokens only — a generic word like "decision" alone would
    /// tag half of any prose paste. Legacy ids from the pre-0.4 rubric are
    /// included so old saved examples normalize on read.
    static let signalAliases: [(alias: String, type: NudgeType)] = [
        // Canonical ids (camelCase pastes normalize to a single token)
        ("talktime", .talkTime), ("talk time", .talkTime),
        ("voiceshare", .voiceShare), ("voice share", .voiceShare),
        ("vagueanswer", .vagueAnswer), ("vague answer", .vagueAnswer),
        ("hedgenotpinned", .hedgeNotPinned), ("hedge", .hedgeNotPinned),
        ("nodecision", .noDecision), ("no decision", .noDecision),
        ("no owner", .noDecision),
        ("alignmentreached", .alignmentReached), ("alignment reached", .alignmentReached),
        ("buriedsignal", .buriedSignal), ("buried signal", .buriedSignal),
        ("stackedquestions", .stackedQuestions), ("stacked questions", .stackedQuestions),
        ("one question at a time", .stackedQuestions),
        ("unansweredquestion", .unansweredQuestion), ("unanswered question", .unansweredQuestion),
        ("interruption", .interruption), ("let them finish", .interruption),
        ("nextsteps", .nextSteps), ("next steps", .nextSteps),
        ("overrun", .overrun), ("over time", .overrun), ("ran over", .overrun),
        ("missingdiscovery", .missingDiscovery), ("no questions", .missingDiscovery),
        ("repetitionloop", .repetitionLoop), ("repetition", .repetitionLoop),
        ("goingquiet", .goingQuiet), ("going quiet", .goingQuiet),
        ("gone quiet", .goingQuiet),
        ("yesman", .yesMan), ("yes man", .yesMan), ("just agreeing", .yesMan),
        ("questionparked", .questionParked), ("parked question", .questionParked),
        ("commitmentgap", .commitmentGap), ("commitment gap", .commitmentGap),
        ("timecheck", .timeCheck), ("time check", .timeCheck),
        ("questionlanded", .questionLanded), ("question landed", .questionLanded),
        ("ownershiphanded", .ownershipHanded), ("ownership handed", .ownershipHanded),
        ("refocused", .refocused),
        ("commitmentlocked", .commitmentLocked), ("commitments locked", .commitmentLocked),
        ("reflectedback", .reflectedBack), ("reflected back", .reflectedBack),
        // Semantic-coach prompt ids
        ("no_decision", .noDecision), ("alignment_reached", .alignmentReached),
        ("buried_signal", .buriedSignal), ("hedge_not_pinned", .hedgeNotPinned),
        ("commitment_escalation", .commitmentGap), ("question_parked", .questionParked),
        // Legacy pre-0.4 rubric ids (old saved examples still carry these)
        ("repetition_loop", .repetitionLoop), ("stacked_asks", .stackedQuestions),
        ("talk_time_imbalance", .talkTime), ("unaddressed_objection", .buriedSignal),
        ("promise_vs_clock", .hedgeNotPinned), ("resolution_capture", .noDecision),
        ("escalation_rising", .commitmentGap),
    ]

    /// Lowercase; underscores/punctuation → spaces; collapse runs. Space-
    /// padded so aliases match on word boundaries ("parked question" never
    /// matches inside "sparked questioning").
    private static func normalized(_ s: String) -> String {
        let mapped = s.lowercased().map { c -> Character in
            (c.isLetter || c.isNumber) ? c : " "
        }
        let collapsed = String(mapped).split(separator: " ").joined(separator: " ")
        return " " + collapsed + " "
    }

    /// First signal type a normalized line refers to, if any.
    private static func matchType(in line: String) -> NudgeType? {
        let norm = normalized(line)
        return signalAliases.first { norm.contains(" \($0.alias.replacingOccurrences(of: "_", with: " ")) ") }?.type
    }

    /// Canonical NudgeType raw value for a stored signalId (which may be a
    /// legacy or semantic id), or nil if it maps to nothing current.
    static func canonicalType(for signalId: String) -> NudgeType? {
        if let direct = NudgeType(rawValue: signalId) { return direct }
        return matchType(in: signalId)
    }

    /// Parse raw coaching feedback text into signal examples.
    /// Structured form:
    ///   "Trigger 1: talkTime" / "Signal: hedge_not_pinned"
    ///   "Evidence: ..." / "Nudge: ..."
    /// Freeform prose falls back to line-level mention scanning, so a paste
    /// like "3. Delist trigger… make talk time nudges earlier" still teaches
    /// the signals it names.
    static func parseFeedback(_ text: String) -> [SignalExample] {
        var results: [SignalExample] = []
        let lines = text.components(separatedBy: .newlines)

        var currentSignal: String?
        var currentEvidence: String?
        var currentNudge: String?

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

            // Signal/Trigger header — an explicit prefix, or a short line
            // that is essentially just a signal name.
            let isHeader = lower.hasPrefix("trigger") || lower.hasPrefix("signal")
                || trimmed.split(separator: " ").count <= 4
            if isHeader, let found = matchType(in: trimmed) {
                flush()
                currentSignal = found.rawValue
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

            if currentSignal != nil && currentEvidence == nil && !trimmed.isEmpty
                && !lower.hasPrefix("#") && !lower.hasPrefix("---") {
                // Inside a structured block: first content line is evidence.
                currentEvidence = trimmed
            } else if currentSignal == nil, !trimmed.isEmpty,
                      let mentioned = matchType(in: trimmed) {
                // Freeform prose mentioning a signal by name — the line
                // itself is the lesson. One example per line, capped length.
                results.append(SignalExample(
                    signalId: mentioned.rawValue,
                    evidence: String(trimmed.prefix(280)),
                    nudge: ""
                ))
            }
        }
        flush()

        return results
    }

    /// All saved examples grouped by canonical NudgeType raw value.
    /// Examples saved before parsing existed (0 parsed signals) are
    /// re-parsed from their raw feedback here, and legacy signal ids are
    /// normalized — old training data keeps teaching without migration.
    static func examplesByType() -> [String: [SignalExample]] {
        var grouped: [String: [SignalExample]] = [:]
        for example in load() {
            let signals = example.signals.isEmpty
                ? parseFeedback(example.feedback)
                : example.signals
            for s in signals {
                guard let type = canonicalType(for: s.signalId) else { continue }
                grouped[type.rawValue, default: []].append(s)
            }
        }
        return grouped
    }

    /// Signal types the user's saved notes call out — these get modestly
    /// more sensitive at session start (the notes are the user saying
    /// "watch for this" in their own words).
    static func emphasizedTypes() -> Set<NudgeType> {
        Set(examplesByType().keys.compactMap(NudgeType.init(rawValue:)))
    }

    /// Threshold/cooldown multiplier for note-emphasized signals. Gentler
    /// than a focus goal — notes accumulate over months; focus is explicit
    /// per-week intent.
    static let sensitivityBoost = 0.9

    private static func extractValue(_ line: String) -> String {
        // Split on first ":" and take the rest
        guard let colonIndex = line.firstIndex(of: ":") else { return line }
        let after = line[line.index(after: colonIndex)...]
        return after.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}
