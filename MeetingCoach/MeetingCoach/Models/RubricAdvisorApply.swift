import Foundation

// Applying advisor suggestions to the active rubric. Lives in its own file
// (not Rubric.swift, which the yamlcheck rig compiles standalone; not
// RubricAdvisor.swift, which the advisorcheck rig compiles without Yams) —
// this is the one place the advisor and the YAML layer meet.

extension Rubric {
    /// The rubric after applying one approved suggestion.
    func applying(_ suggestion: RubricSuggestion) -> Rubric {
        var newBuiltins = builtins
        var newSignals = signals

        if suggestion.signalKey.hasPrefix("custom:") {
            // Custom signals only support removal (their knobs live in the
            // signal entry itself; disable = drop the entry).
            let id = String(suggestion.signalKey.dropFirst("custom:".count))
            newSignals.removeAll { $0.id == id }
        } else {
            var tuning = newBuiltins[suggestion.signalKey] ?? SignalTuning()
            switch suggestion.kind {
            case .disable:
                tuning.enabled = false
            case .raiseCooldown:
                tuning.cooldownMultiplier = min(2.0, tuning.cooldownMultiplier * 1.5)
            case .moreSensitive:
                tuning.thresholdMultiplier = max(0.5, tuning.thresholdMultiplier * 0.85)
            }
            newBuiltins[suggestion.signalKey] = tuning
        }

        return Rubric(name: name, version: version, cadence: cadence,
                      window: window, output: output,
                      signals: newSignals, builtins: newBuiltins)
    }
}

extension RubricAdvisor {
    /// Approve: back up the active rubric, write the patched one, and mark
    /// the suggestion applied. Returns false when the write fails.
    @MainActor
    @discardableResult
    static func approve(_ suggestion: RubricSuggestion, settings: SettingsViewModel) -> Bool {
        let rubric = (try? settings.loadRubricOrDefault()) ?? .builtInDefault
        let patched = rubric.applying(suggestion)
        let yaml = patched.toYAML()
        guard (try? parseRubric(yaml)) != nil else { return false }

        AppSupport.ensureLayout()
        AppSupport.backupActiveRubric(label: "pre-advisor")
        do {
            try yaml.write(to: AppSupport.activeRubricURL, atomically: true, encoding: .utf8)
        } catch {
            mclog("[Advisor] failed to write rubric: \(error.localizedDescription)")
            return false
        }
        settings.rubricPath = AppSupport.activeRubricURL.path
        settings.save()
        markApplied(suggestion)
        mclog("[Advisor] applied \(suggestion.kind.rawValue) to \(suggestion.signalKey)")
        return true
    }
}
