import Foundation

/// Persists per-signal sensitivity multipliers learned from user feedback.
/// Multiplier > 1.0 = less sensitive (thresholds go up).
/// Multiplier < 1.0 = more sensitive (thresholds go down).
enum AdaptiveThresholds {
    private static let key = "adaptiveThresholdMultipliers"
    private static let clampRange = 0.5...2.0

    /// Load the multiplier for a given signal type. Returns 1.0 if not set.
    static func multiplier(for type: NudgeType) -> Double {
        multiplier(forKey: type.rawValue)
    }

    /// Keyed variant — custom rubric signals use "custom:<id>" keys.
    static func multiplier(forKey key: String) -> Double {
        let dict = load()
        return dict[key] ?? 1.0
    }

    /// Process end-of-session feedback and update multipliers.
    static func processSessionFeedback(_ nudges: [Nudge]) {
        var dict = load()

        // Group nudges by signal key (rawValue; "custom:<id>" for customs)
        let grouped = Dictionary(grouping: nudges, by: \.typeKey)
        for (key, typeNudges) in grouped {
            let feedbacks = typeNudges.compactMap(\.feedback)
            guard !feedbacks.isEmpty else {
                // No explicit feedback for this key this session: ignores
                // are a weak negative — half the "annoying" step, and only
                // when at least 3 displayed nudges all went untouched. A
                // single explicit click outweighs a session of silence.
                let ignored = typeNudges.filter { $0.wasIgnored == true }.count
                if ignored >= 3 {
                    let current = dict[key] ?? 1.0
                    dict[key] = min(max(current * 1.05, clampRange.lowerBound),
                                    clampRange.upperBound)
                }
                continue
            }

            let usefulCount = feedbacks.filter { $0 == .useful }.count
            let annoyingCount = feedbacks.filter { $0 == .annoying }.count
            let wrongCount = feedbacks.filter { $0 == .wrong }.count
            let total = feedbacks.count

            let current = dict[key] ?? 1.0

            var adjusted = current
            if Double(annoyingCount) / Double(total) > 0.5 {
                // Mostly annoying — make less sensitive (raise threshold 10%)
                adjusted *= 1.10
            } else if Double(wrongCount) / Double(total) > 0.5 {
                // Mostly wrong — make much less sensitive (raise threshold 15%)
                adjusted *= 1.15
            } else if Double(usefulCount) / Double(total) > 0.5 {
                // Mostly useful — make slightly more sensitive (lower threshold 5%)
                adjusted *= 0.95
            }

            dict[key] = min(max(adjusted, clampRange.lowerBound), clampRange.upperBound)
        }

        save(dict)
    }

    /// Every learned multiplier by signal key, custom signals included —
    /// what the Learned Sensitivity panel shows.
    static func allMultipliersByKey() -> [String: Double] {
        load()
    }

    // MARK: - Private

    /// Decoded-dict cache — engine init calls multiplier() once per signal.
    /// Only touched from the main actor (engine init / session teardown).
    nonisolated(unsafe) private static var cache: [String: Double]?

    private static func load() -> [String: Double] {
        if let cache { return cache }
        let dict: [String: Double]
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            dict = decoded
        } else {
            dict = [:]
        }
        cache = dict
        return dict
    }

    private static func save(_ dict: [String: Double]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        UserDefaults.standard.set(data, forKey: key)
        cache = dict
    }
}
