import SwiftUI

/// The idle-state main pane: streaks, week-over-week movement, focus goals,
/// top patterns, and recent sessions — progress lives in the main window,
/// not buried in Settings. Everything reads from the saved session files.
struct ProgressDashboardView: View {
    var liveSession: LiveSessionViewModel?
    var settings: SettingsViewModel?

    @State private var sessions: [SessionSummary] = []
    @State private var activeGoalIds: [String] = []
    @State private var suggestions: [RubricSuggestion] = []

    private var focusTypes: Set<NudgeType> {
        Set(activeGoalIds.compactMap(FocusGoals.definition(for:)).flatMap(\.types))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("Your Progress", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.title3.bold())
                    Spacer()
                    Button {
                        reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                if sessions.isEmpty {
                    emptyState
                } else {
                    statTiles
                    suggestionSection
                    focusSection
                    topPatterns
                    talkTrend
                    recentSessions
                }
            }
            .padding(20)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.textBackgroundColor))
        .onAppear(perform: reload)
    }

    private func reload() {
        sessions = SessionTrends.loadAll()
        activeGoalIds = FocusGoals.loadActiveIds()
        RubricAdvisor.refresh(sessions: sessions)
        suggestions = RubricAdvisor.pending()
    }

    // MARK: - Sections

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 34))
                .foregroundStyle(.green.opacity(0.5))
            Text("No sessions yet")
                .font(.headline)
            Text("Go live in your next meeting — every session builds your progress picture here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let liveSession {
                Button {
                    liveSession.startDemo()
                } label: {
                    Label("Watch the demo", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var statTiles: some View {
        let (current, best) = SessionTrends.streaks(sessions)
        let thisWeek = SessionTrends.weekStats(sessions, weeksAgo: 0, focusTypes: focusTypes)
        let lastWeek = SessionTrends.weekStats(sessions, weeksAgo: 1, focusTypes: focusTypes)

        return HStack(spacing: 10) {
            StatTile(value: "\(current)",
                     label: current == 1 ? "day streak" : "day streak",
                     sub: best > current ? "best \(best)" : nil)
            StatTile(value: "\(thisWeek.sessionCount)",
                     label: "sessions this week",
                     sub: deltaLabel(now: Double(thisWeek.sessionCount),
                                     before: Double(lastWeek.sessionCount), format: "%.0f"))
            StatTile(value: thisWeek.nudgesPer10Min.map { String(format: "%.1f", $0) } ?? "—",
                     label: "nudges / 10 min",
                     sub: deltaLabel(now: thisWeek.nudgesPer10Min,
                                     before: lastWeek.nudgesPer10Min, format: "%.1f",
                                     lowerIsBetter: true))
            StatTile(value: thisWeek.avgTalkShare.map { "\(Int($0 * 100))%" } ?? "—",
                     label: "avg talk share",
                     sub: deltaLabel(now: thisWeek.avgTalkShare.map { $0 * 100 },
                                     before: lastWeek.avgTalkShare.map { $0 * 100 },
                                     format: "%.0f", suffix: "pt", lowerIsBetter: true))
        }
    }

    private func deltaLabel(now: Double?, before: Double?, format: String,
                            suffix: String = "", lowerIsBetter: Bool = false) -> String? {
        guard let now, let before else { return nil }
        let delta = now - before
        guard abs(delta) >= 0.05 else { return "same as last week" }
        let arrow = delta < 0 ? "↓" : "↑"
        return "\(arrow) \(String(format: format, abs(delta)))\(suffix) vs last week"
    }

    /// The advisor's proposals: approve rewrites the rubric (with backup),
    /// dismiss suppresses until the evidence genuinely grows. Bounded
    /// auto-tuning stays automatic; structural changes always come through
    /// here — nothing changes silently.
    private var suggestionSection: some View {
        Group {
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Coach suggestions", systemImage: "lightbulb")
                        .font(.headline)
                    ForEach(suggestions) { suggestion in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(suggestion.displayName).font(.callout.bold())
                                Text(kindLabel(suggestion.kind))
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.1))
                                    .foregroundStyle(.blue)
                                    .clipShape(Capsule())
                                Spacer()
                            }
                            Text(suggestion.rationale).font(.caption)
                            Text(suggestion.evidence)
                                .font(.caption2).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Button("Apply") {
                                    if let settings {
                                        RubricAdvisor.approve(suggestion, settings: settings)
                                        suggestions = RubricAdvisor.pending()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(settings == nil)

                                Button("Dismiss") {
                                    RubricAdvisor.dismiss(suggestion, sessionCount: sessions.count)
                                    suggestions = RubricAdvisor.pending()
                                }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)
                        }
                        .padding(10)
                        .background(Color.blue.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Text("Small sensitivity adjustments happen automatically from your feedback; changes to what the coach watches always ask first.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func kindLabel(_ kind: RubricSuggestion.Kind) -> String {
        switch kind {
        case .disable: return "turn off"
        case .raiseCooldown: return "fire less often"
        case .moreSensitive: return "fire sooner"
        }
    }

    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Focus").font(.headline)
                Spacer()
                Text("pick up to \(FocusGoals.maxActive)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            // Goal chips
            FlowChips(activeGoalIds: $activeGoalIds)

            if !activeGoalIds.isEmpty {
                let thisWeek = SessionTrends.weekStats(sessions, weeksAgo: 0, focusTypes: focusTypes)
                let lastWeek = SessionTrends.weekStats(sessions, weeksAgo: 1, focusTypes: focusTypes)
                if let now = thisWeek.focusPer10Min {
                    HStack(spacing: 6) {
                        Image(systemName: "target")
                            .foregroundStyle(.blue)
                        Text("Focus nudges: \(String(format: "%.1f", now)) / 10 min this week"
                             + (lastWeek.focusPer10Min.map { String(format: " (last week %.1f)", $0) } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Focused signals fire a little more eagerly and take priority in the overlay.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var topPatterns: some View {
        let patterns = SessionTrends.topPatterns(from: sessions)
        return Group {
            if !patterns.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Top patterns").font(.headline)
                    ForEach(patterns, id: \.type) { pattern in
                        HStack(spacing: 8) {
                            trendIcon(for: pattern.type)
                            Text(pattern.type.displayName).font(.callout)
                            if focusTypes.contains(pattern.type) {
                                Image(systemName: "target")
                                    .font(.caption2).foregroundStyle(.blue)
                            }
                            Spacer()
                            Text("\(pattern.count)×")
                                .font(.system(.caption, design: .monospaced).bold())
                                .foregroundStyle(pattern.count > 10 ? .orange : .secondary)
                        }
                    }
                }
            }
        }
    }

    private var talkTrend: some View {
        let points = sessions.compactMap { s in s.talkShare.map { (s.date, $0) } }
        return Group {
            if points.count >= 3 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Talk share by session").font(.headline)
                    SessionShareChart(points: points)
                        .frame(height: 60)
                }
            }
        }
    }

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Recent sessions").font(.headline)
            ForEach(sessions.suffix(6).reversed()) { session in
                HStack {
                    Text(session.date, style: .date).font(.caption)
                    Text(session.durationFormatted)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let share = session.talkShare {
                        Text("you \(Int(share * 100))%")
                            .font(.caption2)
                            .foregroundStyle(share > 0.65 ? .orange : .secondary)
                    }
                    Spacer()
                    Text("\(session.totalNudges) nudges")
                        .font(.caption2)
                        .foregroundStyle(session.totalNudges > 5 ? .orange : .green)
                }
            }
        }
    }

    private func trendIcon(for type: NudgeType) -> some View {
        let direction = SessionTrends.trend(for: type, in: sessions)
        let (icon, color): (String, Color) = switch direction {
        case .improving: ("arrow.down.right", .green)
        case .worsening: ("arrow.up.right", .orange)
        case .neutral: ("arrow.right", .secondary)
        }
        return Image(systemName: icon)
            .font(.caption)
            .foregroundStyle(color)
    }
}

// MARK: - Pieces

private struct StatTile: View {
    let value: String
    let label: String
    var sub: String?

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(.title2, design: .rounded).bold())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let sub {
                Text(sub)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Focus-goal chips; selection persists immediately.
private struct FlowChips: View {
    @Binding var activeGoalIds: [String]

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(FocusGoals.catalog) { goal in
                let isActive = activeGoalIds.contains(goal.id)
                Button {
                    if isActive {
                        activeGoalIds.removeAll { $0 == goal.id }
                    } else if activeGoalIds.count < FocusGoals.maxActive {
                        activeGoalIds.append(goal.id)
                    }
                    FocusGoals.saveActiveIds(activeGoalIds)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                            .font(.caption)
                        Text(goal.title).font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(isActive ? Color.blue.opacity(0.12) : Color.primary.opacity(0.04))
                    .foregroundStyle(isActive ? Color.blue : Color.secondary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(goal.blurb)
            }
        }
    }
}

/// Dots + line of session talk shares over time, 65% reference line.
private struct SessionShareChart: View {
    let points: [(Date, Double)]
    var warnAt: Double = 0.65

    var body: some View {
        GeometryReader { geo in
            let xs = points.map(\.0.timeIntervalSinceReferenceDate)
            let minX = xs.min() ?? 0
            let maxX = max(xs.max() ?? 1, minX + 1)
            let cgPoints = points.map { point in
                CGPoint(
                    x: geo.size.width * (point.0.timeIntervalSinceReferenceDate - minX) / (maxX - minX),
                    y: geo.size.height * (1 - point.1)
                )
            }
            ZStack {
                Path { p in
                    let y = geo.size.height * (1 - warnAt)
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
                .stroke(Color.orange.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                Path { p in
                    guard let first = cgPoints.first else { return }
                    p.move(to: first)
                    for pt in cgPoints.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(Color.blue.opacity(0.6), lineWidth: 1.5)

                ForEach(Array(cgPoints.enumerated()), id: \.offset) { _, pt in
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 4, height: 4)
                        .position(pt)
                }
            }
        }
    }
}
