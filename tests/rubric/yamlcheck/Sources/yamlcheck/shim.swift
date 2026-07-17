import Foundation

// Shim for app symbols Rubric.swift references, so the real file compiles
// unmodified inside the rig. The tuning types are NOT shimmed — the rig
// symlinks the real Engine/TuningTypes.swift so they can never drift.

func mclog(_ msg: String) {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
}
