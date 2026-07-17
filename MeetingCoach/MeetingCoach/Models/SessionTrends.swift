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
    /// Session talk ratio (0…1 you), when the session recorded one.
    let talkShare: Double?
    /// Nudge counts by stable signal key — rawValue or "custom:<id>".
    let nudgeKeyCounts: [String: Int]
    /// Feedback broken down per signal key (the advisor's evidence).
    let feedbackByKey: [String: [NudgeFeedback: Int]]

    /// Parsed once at load — weekStats walks this per session per call.
    let durationMinutes: Double

    static func minutes(from formatted: String) -> Double {
        let parts = formatted.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return 0 }
        return parts[0] + parts[1] / 60
    }
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

    // MARK: - Streaks & weekly stats

    /// Consecutive-day streaks: `current` counts back from today (a streak
    /// survives until a full day is missed), `best` is the longest run ever.
    static func streaks(_ sessions: [SessionSummary], today: Date = Date()) -> (current: Int, best: Int) {
        let calendar = Calendar.current
        let days = Set(sessions.map { calendar.startOfDay(for: $0.date) }).sorted()
        guard !days.isEmpty else { return (0, 0) }

        var best = 1, run = 1
        for i in 1..<days.count {
            let gap = calendar.dateComponents([.day], from: days[i - 1], to: days[i]).day ?? 0
            run = gap == 1 ? run + 1 : 1
            best = max(best, run)
        }

        var current = 0
        var cursor = calendar.startOfDay(for: today)
        if !days.contains(cursor) {
            // No session yet today — the streak may still be alive from yesterday.
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        while days.contains(cursor) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return (current, best)
    }

    struct WeekStats {
        var sessionCount = 0
        var nudgesPer10Min: Double?
        var avgTalkShare: Double?
        /// Corrective nudges per 10 min for a focused subset of types.
        var focusPer10Min: Double?
    }

    /// Stats for the 7-day window ending `weeksAgo` weeks before now
    /// (0 = the last 7 days, 1 = the 7 days before that). Rolling windows
    /// beat calendar weeks here: "this week vs last" always compares equal
    /// spans, even on a Monday.
    static func weekStats(_ sessions: [SessionSummary], weeksAgo: Int,
                          focusTypes: Set<NudgeType> = [], now: Date = Date()) -> WeekStats {
        let end = now.addingTimeInterval(Double(-weeksAgo) * 7 * 86_400)
        let start = end.addingTimeInterval(-7 * 86_400)
        let window = sessions.filter { $0.date > start && $0.date <= end }

        var stats = WeekStats()
        stats.sessionCount = window.count
        let minutes = window.map(\.durationMinutes).reduce(0, +)
        if minutes >= 5 {
            let nudges = window.map(\.totalNudges).reduce(0, +)
            stats.nudgesPer10Min = Double(nudges) / (minutes / 10)
            if !focusTypes.isEmpty {
                let focused = window
                    .flatMap { $0.nudgeCounts }
                    .filter { focusTypes.contains($0.key) }
                    .map(\.value).reduce(0, +)
                stats.focusPer10Min = Double(focused) / (minutes / 10)
            }
        }
        let shares = window.compactMap(\.talkShare)
        if !shares.isEmpty {
            stats.avgTalkShare = shares.reduce(0, +) / Double(shares.count)
        }
        return stats
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
        var talkShare: Double?

        for line in lines {
            if line.hasPrefix("**Duration:**") {
                duration = line.replacingOccurrences(of: "**Duration:** ", with: "")
            } else if line.hasPrefix("**Utterances:**") {
                utteranceCount = Int(line.replacingOccurrences(of: "**Utterances:** ", with: "")) ?? 0
            } else if line.hasPrefix("**Talk ratio:**") {
                // "**Talk ratio:** 62% you"
                let digits = line.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
                if let pct = Double(digits) { talkShare = pct / 100 }
            }
        }

        // Parse nudges section
        var nudgeCounts: [NudgeType: Int] = [:]
        var nudgeKeyCounts: [String: Int] = [:]
        var feedbackCounts: [NudgeFeedback: Int] = [:]
        var feedbackByKey: [String: [NudgeFeedback: Int]] = [:]
        var inNudges = false
        var totalNudges = 0

        for line in lines {
            if line == "## Nudges" { inNudges = true; continue }
            if line.hasPrefix("## ") && inNudges { break }
            guard inNudges, line.hasPrefix("- [") else { continue }

            totalNudges += 1

            // Parse signal key: **talkTime** or **custom:my_signal**
            var key: String?
            if let typeMatch = line.range(of: #"\*\*[\w:]+\*\*"#, options: .regularExpression) {
                let raw = String(line[typeMatch]).replacingOccurrences(of: "*", with: "")
                key = raw
                nudgeKeyCounts[raw, default: 0] += 1
                let type = NudgeType(rawValue: raw)
                    ?? (raw.hasPrefix("custom:") ? .custom : nil)
                if let type {
                    nudgeCounts[type, default: 0] += 1
                }
            }

            // Parse feedback: feedback: useful
            var feedback: NudgeFeedback?
            if line.contains("feedback: useful") { feedback = .useful }
            else if line.contains("feedback: annoying") { feedback = .annoying }
            else if line.contains("feedback: wrong") { feedback = .wrong }
            if let feedback {
                feedbackCounts[feedback, default: 0] += 1
                if let key {
                    feedbackByKey[key, default: [:]][feedback, default: 0] += 1
                }
            }
        }

        return SessionSummary(
            date: date,
            durationFormatted: duration,
            utteranceCount: utteranceCount,
            nudgeCounts: nudgeCounts,
            totalNudges: totalNudges,
            feedbackCounts: feedbackCounts,
            talkShare: talkShare,
            nudgeKeyCounts: nudgeKeyCounts,
            feedbackByKey: feedbackByKey,
            durationMinutes: SessionSummary.minutes(from: duration)
        )
    }
}
