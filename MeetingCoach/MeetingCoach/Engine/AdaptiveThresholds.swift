import Foundation

/// Persists per-signal sensitivity multipliers learned from user feedback.
/// Multiplier > 1.0 = less sensitive (thresholds go up).
/// Multiplier < 1.0 = more sensitive (thresholds go down).
enum AdaptiveThresholds {
    private static let key = "adaptiveThresholdMultipliers"
    private static let clampRange = 0.5...2.0

    /// Load the multiplier for a given signal type. Returns 1.0 if not set.
    static func multiplier(for type: NudgeType) -> Double {
        let dict = load()
        return dict[type.rawValue] ?? 1.0
    }

    /// Process end-of-session feedback and update multipliers.
    static func processSessionFeedback(_ nudges: [Nudge]) {
        var dict = load()

        // Group nudges by type
        let grouped = Dictionary(grouping: nudges, by: \.type)
        for (type, typeNudges) in grouped {
            let feedbacks = typeNudges.compactMap(\.feedback)
            guard !feedbacks.isEmpty else { continue }

            let usefulCount = feedbacks.filter { $0 == .useful }.count
            let annoyingCount = feedbacks.filter { $0 == .annoying }.count
            let wrongCount = feedbacks.filter { $0 == .wrong }.count
            let total = feedbacks.count

            let current = dict[type.rawValue] ?? 1.0

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

            dict[type.rawValue] = min(max(adjusted, clampRange.lowerBound), clampRange.upperBound)
        }

        save(dict)
    }

    /// Get all current multipliers for display.
    static func allMultipliers() -> [NudgeType: Double] {
        let dict = load()
        var result: [NudgeType: Double] = [:]
        for type in NudgeType.allCases {
            result[type] = dict[type.rawValue] ?? 1.0
        }
        return result
    }

    /// Reset all multipliers to default.
    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: key)
        cache = nil
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
