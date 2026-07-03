import Foundation

/// Parsed summary of a single saved session.
struct SessionSummary: Identifiable {
    let id = UUID()
    let date: Date
    let durationFormatted: String
    let utteranceCount: Int
    let nudgeCounts: [NudgeType: Int]
    let totalNudges: Int
    let feedbackCounts: [NudgeFeedback: Int]
}

/// Reads and parses all saved session files for trend analysis.
enum SessionTrends {
    static func loadAll() -> [SessionSummary] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/MeetingCoach")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        let mdFiles = files.filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return mdFiles.compactMap { parseSession(at: $0) }
    }

    /// Top patterns: which signal types fire most across all sessions.
    static func topPatterns(from sessions: [SessionSummary], limit: Int = 5) -> [(type: NudgeType, count: Int)] {
        var totals: [NudgeType: Int] = [:]
        for session in sessions {
            for (type, count) in session.nudgeCounts {
                totals[type, default: 0] += count
            }
        }
        return totals.sorted { $0.value > $1.value }.prefix(limit).map { (type: $0.key, count: $0.value) }
    }

    /// Trend for a specific signal over recent sessions.
    static func trend(for type: NudgeType, in sessions: [SessionSummary], recentCount: Int = 5) -> TrendDirection {
        let recent = Array(sessions.suffix(recentCount))
        let older = Array(sessions.dropLast(recentCount).suffix(recentCount))
        guard !recent.isEmpty, !older.isEmpty else { return .neutral }

        let recentAvg = Double(recent.map { $0.nudgeCounts[type] ?? 0 }.reduce(0, +)) / Double(recent.count)
        let olderAvg = Double(older.map { $0.nudgeCounts[type] ?? 0 }.reduce(0, +)) / Double(older.count)

        if recentAvg < olderAvg * 0.7 { return .improving }
        if recentAvg > olderAvg * 1.3 { return .worsening }
        return .neutral
    }

    enum TrendDirection {
        case improving, neutral, worsening
    }

    // MARK: - Parsing

    private static func parseSession(at url: URL) -> SessionSummary? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines)

        // Parse date from filename: session_2026-06-30_11-55.md
        let filename = url.deletingPathExtension().lastPathComponent
        let dateStr = filename.replacingOccurrences(of: "session_", with: "")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        guard let date = formatter.date(from: dateStr) else { return nil }

        // Parse header fields
        var duration = ""
        var utteranceCount = 0

        for line in lines {
            if line.hasPrefix("**Duration:**") {
                duration = line.replacingOccurrences(of: "**Duration:** ", with: "")
            } else if line.hasPrefix("**Utterances:**") {
                utteranceCount = Int(line.replacingOccurrences(of: "**Utterances:** ", with: "")) ?? 0
            }
        }

        // Parse nudges section
        var nudgeCounts: [NudgeType: Int] = [:]
        var feedbackCounts: [NudgeFeedback: Int] = [:]
        var inNudges = false
        var totalNudges = 0

        for line in lines {
            if line == "## Nudges" { inNudges = true; continue }
            if line.hasPrefix("## ") && inNudges { break }
            guard inNudges, line.hasPrefix("- [") else { continue }

            totalNudges += 1

            // Parse type: **talkTime**
            if let typeMatch = line.range(of: #"\*\*(\w+)\*\*"#, options: .regularExpression) {
                let raw = String(line[typeMatch]).replacingOccurrences(of: "*", with: "")
                if let type = NudgeType(rawValue: raw) {
                    nudgeCounts[type, default: 0] += 1
                }
            }

            // Parse feedback: feedback: useful
            if line.contains("feedback: useful") { feedbackCounts[.useful, default: 0] += 1 }
            else if line.contains("feedback: annoying") { feedbackCounts[.annoying, default: 0] += 1 }
            else if line.contains("feedback: wrong") { feedbackCounts[.wrong, default: 0] += 1 }
        }

        return SessionSummary(
            date: date,
            durationFormatted: duration,
            utteranceCount: utteranceCount,
            nudgeCounts: nudgeCounts,
            totalNudges: totalNudges,
            feedbackCounts: feedbackCounts
        )
    }
}
