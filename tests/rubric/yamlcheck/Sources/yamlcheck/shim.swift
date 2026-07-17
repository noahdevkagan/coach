import Foundation

// Shims for app symbols Rubric.swift references, so the real file compiles
// unmodified inside the rig. Mirrors of the engine-layer types — keep in
// sync with SignalEngine.swift / SemanticCoach.swift / Coach.swift.

struct SignalTuning: Sendable {
    var enabled: Bool = true
    var thresholdMultiplier: Double = 1.0
    var cooldownMultiplier: Double = 1.0
}

typealias RubricTuning = [String: SignalTuning]

struct CustomSemanticSignal: Sendable {
    let id: String
    let name: String
    let description: String
}

func mclog(_ msg: String) {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
}
