import Foundation
import SwiftUI

/// Backing state for the rubric builder: the active rubric decomposed into
/// editable rows (built-in signal tuning + custom semantic signals), a
/// plain-English request box that a local LLM turns into rubric YAML, and
/// save/backup plumbing. Works fully manually when no model is installed.
@MainActor @Observable
final class RubricBuilderViewModel {

    struct BuiltinRow: Identifiable {
        let type: NudgeType
        let blurb: String
        var enabled: Bool = true
        var level: Level = .normal
        /// The tuning as loaded, plus the level it quantized to. When the
        /// user doesn't move the level, the original multipliers pass
        /// through untouched — the coarse More/Normal/Fewer buckets must
        /// never clobber precise values (e.g. an advisor cooldown patch).
        var loadedTuning: SignalTuning?
        var loadedLevel: Level = .normal
        var id: String { type.rawValue }

        enum Level: String, CaseIterable, Identifiable {
            case more = "More"
            case normal = "Normal"
            case fewer = "Fewer"
            var id: String { rawValue }

            /// Threshold/cooldown multiplier (>1 relaxes, <1 tightens).
            var multiplier: Double {
                switch self {
                case .more: return 0.7
                case .normal: return 1.0
                case .fewer: return 1.5
                }
            }

            static func from(multiplier: Double) -> Level {
                if multiplier < 0.9 { return .more }
                if multiplier > 1.15 { return .fewer }
                return .normal
            }
        }
    }

    struct CustomRow: Identifiable {
        let id = UUID()
        var signalId: String
        var description: String
        var nudge: String
        /// Source-signal fields the editor doesn't surface — carried through
        /// saves so a hand-authored rubric round-trips faithfully.
        var tier: String = "B"
        var needsDiarization = false
        var minConfidence = 0.8
    }

    var request = ""
    var builtinRows: [BuiltinRow] = []
    var customRows: [CustomRow] = []
    var isGenerating = false
    var error: String?
    var saved = false
    var rubricName = "my-rubric"

    /// Non-row rubric fields (cadence/window/output and legacy signals)
    /// carried through saves untouched.
    private var base: Rubric = .builtInDefault

    /// The tunable built-ins, grouped for display. Order matters — the most
    /// user-meaningful signals first.
    static let instantTypes: [(NudgeType, String)] = [
        (.talkTime, "one long monologue holding the floor"),
        (.voiceShare, "dominating the word count over several minutes"),
        (.interruption, "cutting the other person off mid-thought"),
        (.stackedQuestions, "asking 3+ questions in one breath"),
        (.unansweredQuestion, "talking past a question they asked you"),
        (.missingDiscovery, "going too long without asking anything"),
        (.repetitionLoop, "circling back to the same point"),
        (.vagueAnswer, "vague replies to your direct questions"),
        (.goingQuiet, "the other side going quiet / short replies"),
        (.yesMan, "agreeing with everything without pushback"),
        (.nextSteps, "meeting ending with no next steps"),
        (.timeCheck, "time running low on the scheduled slot"),
        (.overrun, "running past the scheduled end"),
    ]
    static let aiTypes: [(NudgeType, String)] = [
        (.noDecision, "open topic with no decision, owner, or date"),
        (.alignmentReached, "agreement reached but discussion continues"),
        (.buriedSignal, "high-stakes statement passed over"),
        (.hedgeNotPinned, "soft commitment never pinned to a date"),
        (.commitmentGap, "your commitment quietly growing in scope"),
        (.questionParked, "your question deflected repeatedly"),
    ]
    static let greenTypes: [(NudgeType, String)] = [
        (.questionLanded, "a short open question that opened them up"),
        (.ownershipHanded, "handing the decision to them"),
        (.refocused, "pulling a drifting room back on track"),
        (.commitmentLocked, "locking commitments with owner and date"),
        (.reflectedBack, "reflecting their point back before responding"),
    ]

    private static var allTypes: [(NudgeType, String)] {
        instantTypes + aiTypes + greenTypes
    }

    // MARK: - Load / build

    func load(from rubric: Rubric) {
        base = rubric
        rubricName = rubric.name
        builtinRows = Self.allTypes.map { type, blurb in
            var row = BuiltinRow(type: type, blurb: blurb)
            if let tuning = rubric.builtins[type.rawValue] {
                row.enabled = tuning.enabled
                row.level = .from(multiplier: tuning.thresholdMultiplier)
                row.loadedTuning = tuning
                row.loadedLevel = row.level
            }
            return row
        }
        // Every non-builtin-alias signal becomes a row — the live coach caps
        // how many it watches, but the editor must never drop any on save.
        customRows = rubric.signals
            .filter { !Rubric.builtinSignalIds.contains($0.id) }
            .map {
                CustomRow(signalId: $0.id, description: $0.description,
                          nudge: $0.nudge, tier: $0.tier,
                          needsDiarization: $0.needsDiarization,
                          minConfidence: $0.minConfidence)
            }
    }

    /// Assemble a Rubric from the current rows, carrying base fields through.
    func currentRubric() -> Rubric {
        var builtins: RubricTuning = [:]
        for row in builtinRows {
            // Untouched level → the loaded multipliers pass through exactly
            // (an advisor cooldown patch quantizes to .normal; re-emitting
            // the bucket value would silently revert it).
            var tuning = row.loadedTuning ?? SignalTuning()
            if row.level != row.loadedLevel {
                tuning.thresholdMultiplier = row.level.multiplier
                tuning.cooldownMultiplier = row.level.multiplier
            }
            tuning.enabled = row.enabled
            // Only keep entries that differ from stock.
            if !tuning.enabled || tuning.thresholdMultiplier != 1.0 || tuning.cooldownMultiplier != 1.0 {
                builtins[row.type.rawValue] = tuning
            }
        }

        // Legacy signals whose ids alias built-ins pass through unchanged
        // (they still drive the offline simulator path); custom rows replace
        // the rest.
        let legacy = base.signals.filter { Rubric.builtinSignalIds.contains($0.id) }
        let customs: [Signal] = customRows.compactMap { row in
            let id = Self.snakeCase(row.signalId)
            guard !id.isEmpty, !row.description.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return Signal(id: id, tier: row.tier, description: row.description,
                          nudge: row.nudge, needsDiarization: row.needsDiarization,
                          minConfidence: row.minConfidence)
        }

        let name = rubricName.trimmingCharacters(in: .whitespaces)
        return Rubric(name: name.isEmpty ? "my-rubric" : name,
                      version: base.version,
                      cadence: base.cadence,
                      window: base.window,
                      output: base.output,
                      signals: legacy + customs,
                      builtins: builtins)
    }

    static func snakeCase(_ s: String) -> String {
        s.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "_" }
            .joined()
            .split(separator: "_").joined(separator: "_")
    }

    // MARK: - Generate (local LLM)

    func generate(settings: SettingsViewModel, ollamaManager: OllamaManager) {
        let ask = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ask.isEmpty, !isGenerating else { return }
        isGenerating = true
        error = nil
        saved = false

        if ollamaManager.status == .stopped {
            ollamaManager.start()
        }
        let model = settings.selectedModel

        Task {
            defer { isGenerating = false }
            if ollamaManager.status != .running {
                for _ in 1...30 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if ollamaManager.status == .running { break }
                    if case .error = ollamaManager.status { break }
                }
            }
            guard ollamaManager.status == .running else {
                error = "The local AI engine isn't running — adjust the toggles manually, or install a model in Settings."
                return
            }

            let client = OllamaClient(model: model, timeout: 90)
            let currentYAML = currentRubric().toYAML()
            let (system, user) = Self.buildPrompt(currentYAML: currentYAML, request: ask)

            var lastError = ""
            for attempt in 1...2 {
                do {
                    let extra = attempt == 1 ? "" :
                        "\n\nYour previous output failed to parse (\(lastError)). Output ONLY valid rubric YAML this time."
                    let raw = try await client.complete(system: system, user: user + extra)
                    let yaml = Self.stripFences(raw)
                    let rubric = try parseRubric(yaml)
                    load(from: rubric)
                    mclog("[RubricBuilder] Generated rubric '\(rubric.name)' (attempt \(attempt))")
                    return
                } catch {
                    lastError = error.localizedDescription
                    mclog("[RubricBuilder] attempt \(attempt) failed: \(lastError)")
                }
            }
            error = "Couldn't turn that into a rubric — try rephrasing, or adjust the toggles manually."
        }
    }

    private static func buildPrompt(currentYAML: String, request: String) -> (String, String) {
        let catalog = allTypes
            .map { "- \($0.0.rawValue): \($0.1)" }
            .joined(separator: "\n")
        let system = """
        You edit YAML rubric files for Meeting Coach, a real-time meeting coaching app. \
        You receive the current rubric and a user request; you output the complete updated rubric YAML.

        Schema:
        - builtins: (optional) map of built-in signal tuning, keyed by signal id. Each value: \
        { enabled: <bool>, threshold_multiplier: <number>, cooldown_multiplier: <number> }. \
        threshold_multiplier > 1 means FEWER nudges of that kind (relaxed), < 1 means MORE (sensitive). \
        Stay within 0.5–2.0. Valid builtin ids and what each watches for:
        \(catalog)
        - signals: (optional) list of custom signals watched live by a local AI. Each item: \
        id (snake_case, descriptive), tier ("B"), description (one sentence: exactly what pattern to look for in the transcript), \
        nudge (the short line shown mid-meeting, max 8 words, imperative).

        Rules:
        - Prefer tuning builtins over adding a custom signal when a builtin already covers the request.
        - Keep every part of the current rubric the user didn't ask to change.
        - At most 6 custom signals total.
        - Output ONLY the complete YAML file. No commentary, no code fences.
        """
        let user = """
        Current rubric:

        \(currentYAML)

        User request: \(request)
        """
        return (system, user)
    }

    private static func stripFences(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            // Drop the opening fence line and the closing fence.
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let closing = text.range(of: "```", options: .backwards) {
                text = String(text[..<closing.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Save

    func save(settings: SettingsViewModel) {
        let rubric = currentRubric()
        let yaml = rubric.toYAML()

        // Validate the exact bytes we're about to write — a rubric that
        // doesn't round-trip must never become the active file.
        do {
            _ = try parseRubric(yaml)
        } catch {
            self.error = "Internal error: rubric failed validation, not saved."
            return
        }

        AppSupport.ensureLayout()
        AppSupport.backupActiveRubric(label: "pre-builder")
        do {
            try yaml.write(to: AppSupport.activeRubricURL, atomically: true, encoding: .utf8)
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
            return
        }
        settings.rubricPath = AppSupport.activeRubricURL.path
        settings.save()
        saved = true
        mclog("[RubricBuilder] Saved rubric '\(rubric.name)' to \(AppSupport.activeRubricURL.path)")
    }
}
