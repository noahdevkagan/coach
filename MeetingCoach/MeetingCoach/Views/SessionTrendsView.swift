import SwiftUI

/// Shows coaching trends across saved sessions.
struct SessionTrendsView: View {
    @State private var sessions: [SessionSummary] = []
    @State private var isLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Coaching Trends", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.headline)
                Spacer()
                Button {
                    sessions = SessionTrends.loadAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if sessions.isEmpty {
                Text("No sessions yet. Complete a live session to see trends.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                // Summary stats
                HStack(spacing: 16) {
                    StatBox(label: "Sessions", value: "\(sessions.count)")
                    StatBox(label: "Total Nudges", value: "\(sessions.map(\.totalNudges).reduce(0, +))")
                    StatBox(label: "Avg/Session", value: String(format: "%.1f", Double(sessions.map(\.totalNudges).reduce(0, +)) / Double(sessions.count)))
                }

                // Top patterns
                let patterns = SessionTrends.topPatterns(from: sessions)
                if !patterns.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your Top Patterns").font(.caption.bold())
                        ForEach(patterns, id: \.type) { pattern in
                            HStack(spacing: 6) {
                                trendIcon(for: pattern.type)
                                Text(pattern.type.displayName)
                                    .font(.caption)
                                Spacer()
                                Text("\(pattern.count)x")
                                    .font(.system(.caption, design: .monospaced).bold())
                                    .foregroundStyle(pattern.count > 10 ? .orange : .secondary)
                            }
                        }
                    }
                }

                // Adaptive thresholds (custom rubric signals included)
                let multipliers = AdaptiveThresholds.allMultipliersByKey()
                    .filter { $0.value != 1.0 }
                if !multipliers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Learned Sensitivity").font(.caption.bold())
                        ForEach(multipliers.sorted(by: { $0.key < $1.key }), id: \.key) { key, mult in
                            HStack(spacing: 6) {
                                Text(displayName(forKey: key))
                                    .font(.caption)
                                Spacer()
                                Text(mult < 1.0 ? "more sensitive" : "less sensitive")
                                    .font(.caption2)
                                    .foregroundStyle(mult < 1.0 ? .green : .orange)
                                Text(String(format: "%.0f%%", (mult - 1.0) * 100))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Recent sessions
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Sessions").font(.caption.bold())
                    ForEach(sessions.suffix(5).reversed()) { session in
                        HStack {
                            Text(session.date, style: .date)
                                .font(.caption2)
                            Text(session.durationFormatted)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(session.totalNudges) nudges")
                                .font(.caption2)
                                .foregroundStyle(session.totalNudges > 5 ? .orange : .green)
                        }
                    }
                }
            }
        }
        .onAppear {
            if !isLoaded {
                sessions = SessionTrends.loadAll()
                isLoaded = true
            }
        }
    }

    private func displayName(forKey key: String) -> String {
        if key.hasPrefix("custom:") {
            return key.dropFirst("custom:".count)
                .split(separator: "_").map(\.capitalized).joined(separator: " ")
        }
        return NudgeType(rawValue: key)?.displayName ?? key
    }

    private func trendIcon(for type: NudgeType) -> some View {
        let direction = SessionTrends.trend(for: type, in: sessions)
        let (icon, color): (String, Color) = switch direction {
        case .improving: ("arrow.down.right", .green)
        case .worsening: ("arrow.up.right", .orange)
        case .neutral: ("arrow.right", .secondary)
        }
        return Image(systemName: icon)
            .font(.caption2)
            .foregroundStyle(color)
    }
}

private struct StatBox: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).bold())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
