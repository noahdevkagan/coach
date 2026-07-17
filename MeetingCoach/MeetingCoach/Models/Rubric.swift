import Foundation
import Yams

struct Signal: Identifiable, Sendable {
    let id: String
    let tier: String
    let description: String
    let nudge: String
    let needsDiarization: Bool
    let minConfidence: Double
}

struct Cadence: Sendable {
    var heartbeatSeconds: Int = 45
    var extraCheckOnLongPauseSeconds: Int = 8
    var extraCheckOnSpeakerHandoff: Bool = true
}

struct TranscriptWindow: Sendable {
    var transcriptSeconds: Int = 240
    var keepRunningSummary: Bool = true
}

struct OutputConfig: Sendable {
    var maxCallsPerTrigger: Int = 3
    var minConfidenceToShow: Double = 0.55
}

struct Rubric: Sendable {
    let name: String
    let version: Int
    var cadence: Cadence
    let window: TranscriptWindow
    let output: OutputConfig
    let signals: [Signal]
    /// Tuning for the built-in signals (deterministic monitors and the
    /// semantic six), keyed by NudgeType.rawValue. Missing keys mean
    /// "enabled, stock thresholds" — a rubric without this section behaves
    /// exactly like today's hardcoded engine.
    var builtins: RubricTuning = [:]

    func signal(byId id: String) -> Signal? {
        signals.first { $0.id == id }
    }
}

extension Rubric {
    /// Built-in generic rubric, mirroring rubrics/default.yaml. Used when no
    /// rubric file is configured or the configured path is missing, so a fresh
    /// install coaches with person-neutral signals instead of an empty rubric.
    static let builtInDefault = Rubric(
        name: "default", version: 1,
        cadence: Cadence(), window: TranscriptWindow(),
        output: OutputConfig(maxCallsPerTrigger: 3, minConfidenceToShow: 0.6),
        signals: [
            Signal(id: "no_decision_owner_date", tier: "A",
                   description: "A clear question has been open too long with no decision, owner, and date stated.",
                   nudge: "This has been open a while with nothing named. Decide it or park it.",
                   needsDiarization: false, minConfidence: 0.6),
            Signal(id: "alignment_reached_still_talking", tier: "A",
                   description: "Two or more people state compatible positions on the open question.",
                   nudge: "Sounds like agreement. Consider closing this out.",
                   needsDiarization: false, minConfidence: 0.6),
            Signal(id: "reopening_closed_thread", tier: "A",
                   description: "A previously resolved topic gets relitigated.",
                   nudge: "This seemed settled earlier. Intentional, or drift?",
                   needsDiarization: false, minConfidence: 0.6),
            Signal(id: "buried_signal_ignored", tier: "A",
                   description: "A high-stakes statement (a metric, a risk, a concern) the conversation moves past.",
                   nudge: "That sounded important and the conversation moved on.",
                   needsDiarization: false, minConfidence: 0.6),
            Signal(id: "hedge_not_pinned", tier: "B",
                   description: "A commitment stated as a range or soft language.",
                   nudge: "That was a range, not a firm commitment. Worth pinning down.",
                   needsDiarization: false, minConfidence: 0.8),
        ])
}

func loadRubric(from url: URL) throws -> Rubric {
    try parseRubric(try String(contentsOf: url, encoding: .utf8))
}

func parseRubric(_ text: String) throws -> Rubric {
    guard let yaml = try Yams.load(yaml: text) as? [String: Any] else {
        throw RubricError.invalidFormat
    }

    let name = yaml["name"] as? String ?? "unknown"
    let version = yaml["version"] as? Int ?? 1

    // Cadence
    let cadDict = yaml["cadence"] as? [String: Any] ?? [:]
    let cadence = Cadence(
        heartbeatSeconds: cadDict["heartbeat_seconds"] as? Int ?? 45,
        extraCheckOnLongPauseSeconds: cadDict["extra_check_on_long_pause_seconds"] as? Int ?? 8,
        extraCheckOnSpeakerHandoff: cadDict["extra_check_on_speaker_handoff"] as? Bool ?? true
    )

    // Window
    let winDict = yaml["window"] as? [String: Any] ?? [:]
    let window = TranscriptWindow(
        transcriptSeconds: winDict["transcript_seconds"] as? Int ?? 240,
        keepRunningSummary: winDict["keep_running_summary"] as? Bool ?? true
    )

    // Output
    let outDict = yaml["output"] as? [String: Any] ?? [:]
    let output = OutputConfig(
        maxCallsPerTrigger: outDict["max_calls_per_trigger"] as? Int ?? 3,
        minConfidenceToShow: outDict["min_confidence_to_show"] as? Double ?? 0.55
    )

    // Tiers
    let tiersDict = yaml["tiers"] as? [String: [String: Any]] ?? [:]
    var tierFloors: [String: Double] = [:]
    for (tierName, tierConf) in tiersDict {
        tierFloors[tierName] = tierConf["min_confidence"] as? Double ?? 0.55
    }

    // Signals
    let signalList = yaml["signals"] as? [[String: Any]] ?? []
    let signals: [Signal] = signalList.compactMap { dict in
        guard let id = dict["id"] as? String,
              let tier = dict["tier"] as? String,
              let desc = dict["description"] as? String else { return nil }
        let nudge = dict["nudge"] as? String ?? ""
        let needsDia = dict["needs_diarization"] as? Bool ?? false
        let floor = tierFloors[tier] ?? 0.55
        return Signal(id: id, tier: tier, description: desc, nudge: nudge,
                      needsDiarization: needsDia, minConfidence: floor)
    }

    // Built-in signal tuning
    var builtins: RubricTuning = [:]
    if let builtinsDict = yaml["builtins"] as? [String: Any] {
        for (key, raw) in builtinsDict {
            guard let conf = raw as? [String: Any] else { continue }
            var tuning = SignalTuning()
            tuning.enabled = conf["enabled"] as? Bool ?? true
            tuning.thresholdMultiplier = doubleValue(conf["threshold_multiplier"]) ?? 1.0
            tuning.cooldownMultiplier = doubleValue(conf["cooldown_multiplier"]) ?? 1.0
            builtins[key] = tuning
        }
    }

    return Rubric(name: name, version: version, cadence: cadence,
                  window: window, output: output, signals: signals,
                  builtins: builtins)
}

/// YAML numbers arrive as Int when whole ("1" vs "1.0") — accept both.
private func doubleValue(_ any: Any?) -> Double? {
    if let d = any as? Double { return d }
    if let i = any as? Int { return Double(i) }
    return nil
}

enum RubricError: Error, LocalizedError {
    case invalidFormat
    var errorDescription: String? { "Invalid rubric YAML format" }
}

// MARK: - Custom semantic signals

extension Rubric {
    /// Rubric signal ids already covered by built-in detectors — the semantic
    /// six by their prompt ids, plus legacy ids from shipped rubrics that
    /// alias deterministic or semantic built-ins. Anything else in a rubric's
    /// signal list becomes a custom signal watched by the live LLM coach.
    static let builtinSignalIds: Set<String> = [
        // Semantic six (SemanticCoach prompt ids)
        "no_decision", "alignment_reached", "buried_signal",
        "hedge_not_pinned", "commitment_escalation", "question_parked",
        // Legacy aliases from shipped rubrics, covered by built-ins
        "no_decision_owner_date", "alignment_reached_still_talking",
        "buried_signal_ignored", "repetition_loop", "escalation_rising",
        "resolution_capture", "unaddressed_objection", "stacked_asks",
        "global_negative", "positive_reinforcement", "talk_time_imbalance",
        "promise_vs_clock",
    ]

    /// Signals the live semantic coach should watch beyond its built-in set.
    /// Capped so the prompt stays disciplined — precision beats coverage.
    var customSemanticSignals: [CustomSemanticSignal] {
        Array(signals
            .filter { !Self.builtinSignalIds.contains($0.id) }
            .prefix(6))
            .map {
                CustomSemanticSignal(id: $0.id,
                                     name: Self.displayName(fromId: $0.id),
                                     description: $0.description)
            }
    }

    static func displayName(fromId id: String) -> String {
        id.split(separator: "_").map(\.capitalized).joined(separator: " ")
    }
}

// MARK: - Serialization (rubric builder)

extension Rubric {
    /// Serialize to the YAML format parseRubric reads. Only the sections the
    /// builder edits are written; neutral builtins entries are omitted so a
    /// stock rubric round-trips to a clean file.
    func toYAML() -> String {
        var lines: [String] = []
        lines.append("# Meeting Coach rubric — edited by the in-app builder.")
        lines.append("version: \(version)")
        lines.append("name: \(yamlQuote(name))")
        lines.append("")
        lines.append("cadence:")
        lines.append("  heartbeat_seconds: \(cadence.heartbeatSeconds)")
        lines.append("  extra_check_on_long_pause_seconds: \(cadence.extraCheckOnLongPauseSeconds)")
        lines.append("  extra_check_on_speaker_handoff: \(cadence.extraCheckOnSpeakerHandoff)")
        lines.append("")
        lines.append("window:")
        lines.append("  transcript_seconds: \(window.transcriptSeconds)")
        lines.append("  keep_running_summary: \(window.keepRunningSummary)")
        lines.append("")
        lines.append("output:")
        lines.append("  max_calls_per_trigger: \(output.maxCallsPerTrigger)")
        lines.append("  min_confidence_to_show: \(output.minConfidenceToShow)")
        lines.append("")
        lines.append("tiers:")
        lines.append("  A: { min_confidence: 0.6 }")
        lines.append("  B: { min_confidence: 0.8 }")

        let tuned = builtins
            .filter { !$0.value.enabled || $0.value.thresholdMultiplier != 1.0 || $0.value.cooldownMultiplier != 1.0 }
            .sorted { $0.key < $1.key }
        if !tuned.isEmpty {
            lines.append("")
            lines.append("builtins:")
            for (key, t) in tuned {
                lines.append("  \(key): { enabled: \(t.enabled), threshold_multiplier: \(t.thresholdMultiplier), cooldown_multiplier: \(t.cooldownMultiplier) }")
            }
        }

        if !signals.isEmpty {
            lines.append("")
            lines.append("signals:")
            for s in signals {
                lines.append("  - id: \(s.id)")
                lines.append("    tier: \(s.tier)")
                lines.append("    description: \(yamlQuote(s.description))")
                lines.append("    nudge: \(yamlQuote(s.nudge))")
                if s.needsDiarization {
                    lines.append("    needs_diarization: true")
                }
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

private func yamlQuote(_ s: String) -> String {
    "\"" + s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: " ")
    + "\""
}
