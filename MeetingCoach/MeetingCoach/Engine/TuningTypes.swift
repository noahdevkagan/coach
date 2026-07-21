import Foundation

// The plain-data bridge between the YAML rubric layer and the engines.
// Kept in one small Foundation-only file so every harness that compiles an
// engine standalone (bench, sigcheck, tuningcheck, democheck, yamlcheck)
// includes the REAL definitions instead of drifting shims.

/// Per-signal tuning from the active rubric, keyed by NudgeType.rawValue.
/// Defaults are neutral: an empty map is byte-identical to stock behavior.
struct SignalTuning: Sendable, Equatable {
    var enabled: Bool = true
    /// >1 relaxes the trigger (fewer nudges), <1 tightens it — the same
    /// convention as the meeting-type and adaptive multipliers.
    var thresholdMultiplier: Double = 1.0
    var cooldownMultiplier: Double = 1.0
}

typealias RubricTuning = [String: SignalTuning]

/// The v2 default cut: out of the box only a handful of high-bar signals
/// coach — talkTime (tuned rarer), stackedQuestions, nextSteps,
/// commitmentLocked (the single green), and semantic hedgeNotPinned
/// (absent keys = enabled, stock thresholds). Everything else is off until
/// re-enabled in Coaching Style. Single source of truth for the shipped
/// default_rubric.yaml, Rubric.builtInDefault, the v2 migration, and the
/// rubric test rigs — keep them in sync through this map only.
enum DefaultBuiltins {
    static let cut: RubricTuning = {
        var t = RubricTuning()
        // Kept, but rarer: raise the floor and double the cooldown.
        t["talkTime"] = SignalTuning(enabled: true,
                                     thresholdMultiplier: 1.5,
                                     cooldownMultiplier: 2.0)
        let off = [
            // Deterministic monitors
            "missingDiscovery", "timeCheck", "repetitionLoop", "goingQuiet",
            "yesMan", "unansweredQuestion", "interruption", "vagueAnswer",
            "overrun", "voiceShare", "questionParked",
            // buriedSignal disables both HighStakesSignal and the semantic def
            "buriedSignal",
            // Positives — commitmentLocked stays as the single green
            "questionLanded", "ownershipHanded", "refocused", "reflectedBack",
            // Semantic (hedgeNotPinned stays)
            "noDecision", "alignmentReached", "commitmentGap",
        ]
        for key in off { t[key] = SignalTuning(enabled: false) }
        return t
    }()

    /// The cut as a YAML `builtins:` block, in the same shape the builder's
    /// round-trip writer emits. Used by the v2 migration to patch old files.
    static func yamlBlock() -> String {
        var lines = ["builtins:"]
        for (key, t) in cut.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(key): { enabled: \(t.enabled), threshold_multiplier: \(t.thresholdMultiplier), cooldown_multiplier: \(t.cooldownMultiplier) }")
        }
        return lines.joined(separator: "\n")
    }
}

/// A rubric-defined signal the semantic coach watches beyond its built-in
/// set (id is the snake_case rubric id; name is what the UI shows).
struct CustomSemanticSignal: Sendable {
    let id: String
    let name: String
    let description: String
}
