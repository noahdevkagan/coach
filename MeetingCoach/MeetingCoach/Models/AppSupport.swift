import Foundation

/// Canonical on-disk layout under ~/Library/Application Support/MeetingCoach/.
/// Everything user-visible (rubrics, suggestions, goals) lives here so it
/// survives app updates and never depends on a dev-machine checkout path.
enum AppSupport {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MeetingCoach", isDirectory: true)
    }

    static var rubricsDir: URL { root.appendingPathComponent("rubrics", isDirectory: true) }
    static var rubricHistoryDir: URL { rubricsDir.appendingPathComponent("history", isDirectory: true) }
    static var activeRubricURL: URL { rubricsDir.appendingPathComponent("active.yaml") }
    static var suggestionsURL: URL { root.appendingPathComponent("suggestions.json") }
    static var goalsURL: URL { root.appendingPathComponent("goals.json") }

    /// Create the directory layout and seed rubrics/active.yaml from the
    /// bundled default rubric on first run. Safe to call repeatedly.
    static func ensureLayout() {
        let fm = FileManager.default
        for dir in [rubricsDir, rubricHistoryDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard !fm.fileExists(atPath: activeRubricURL.path) else { return }
        if let bundled = Bundle.main.url(forResource: "default_rubric", withExtension: "yaml") {
            try? fm.copyItem(at: bundled, to: activeRubricURL)
        }
    }

    /// Snapshot the current active rubric into rubrics/history/ before a
    /// structural change (builder save, advisor patch). Returns the backup URL.
    @discardableResult
    static func backupActiveRubric(label: String) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: activeRubricURL.path) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dest = rubricHistoryDir.appendingPathComponent("\(stamp)-\(label).yaml")
        try? fm.createDirectory(at: rubricHistoryDir, withIntermediateDirectories: true)
        try? fm.copyItem(at: activeRubricURL, to: dest)
        return dest
    }
}
