import Foundation

// The plain-data bridge between the YAML rubric layer and the engines.
// Kept in one small Foundation-only file so every harness that compiles an
// engine standalone (bench, sigcheck, tuningcheck, democheck, yamlcheck)
// includes the REAL definitions instead of drifting shims.

/// Per-signal tuning from the active rubric, keyed by NudgeType.rawValue.
/// Defaults are neutral: an empty map is byte-identical to stock behavior.
struct SignalTuning: Sendable {
    var enabled: Bool = true
    /// >1 relaxes the trigger (fewer nudges), <1 tightens it — the same
    /// convention as the meeting-type and adaptive multipliers.
    var thresholdMultiplier: Double = 1.0
    var cooldownMultiplier: Double = 1.0
}

typealias RubricTuning = [String: SignalTuning]

/// A rubric-defined signal the semantic coach watches beyond its built-in
/// set (id is the snake_case rubric id; name is what the UI shows).
struct CustomSemanticSignal: Sendable {
    let id: String
    let name: String
    let description: String
}
