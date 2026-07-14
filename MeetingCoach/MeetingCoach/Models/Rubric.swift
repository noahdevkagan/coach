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
    let text = try String(contentsOf: url, encoding: .utf8)
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

    return Rubric(name: name, version: version, cadence: cadence,
                  window: window, output: output, signals: signals)
}

enum RubricError: Error, LocalizedError {
    case invalidFormat
    var errorDescription: String? { "Invalid rubric YAML format" }
}
