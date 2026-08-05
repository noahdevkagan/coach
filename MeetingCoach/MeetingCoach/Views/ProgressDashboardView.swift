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
                // No manual refresh: the pane reloads on every appearance,
                // which is the only time its numbers can be stale.
                Text("Your progress")
                    .font(Dorado.barlowXBold(28))
                    .foregroundStyle(Dorado.midnight)

                if sessions.isEmpty {
                    OnboardingChecklistView(liveSession: liveSession, settings: settings)
                } else {
                    statTiles
                    suggestionSection
                    // focusSection intentionally not shown: focus goals are
                    // off the zero-config main path (v2 pivot). The picker
                    // code stays below for the Advanced era to re-wire.
                    topPatterns
                    talkTrend
                    recentSessions
                }
            }
            .padding(.init(top: 28, leading: 44, bottom: 28, trailing: 44))
            .frame(maxWidth: 728, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.white)
        .onAppear(perform: reload)
    }

    private func reload() {
        sessions = SessionTrends.loadAll()
        activeGoalIds = FocusGoals.loadActiveIds()
        RubricAdvisor.refresh(sessions: sessions)
        suggestions = RubricAdvisor.pending()
    }

    // MARK: - Sections

    private var statTiles: some View {
        let (current, best) = SessionTrends.streaks(sessions)
        let thisWeek = SessionTrends.weekStats(sessions, weeksAgo: 0, focusTypes: focusTypes)
        let lastWeek = SessionTrends.weekStats(sessions, weeksAgo: 1, focusTypes: focusTypes)

        return HStack(spacing: 10) {
            StatTile(value: "\(current)",
                     label: "day streak",
                     sub: best > current ? "best \(best)" : nil)
            StatTile(value: "\(thisWeek.sessionCount)",
                     label: "sessions this week",
                     sub: deltaLabel(now: Double(thisWeek.sessionCount),
                                     before: Double(lastWeek.sessionCount), format: "%.0f"))
            StatTile(value: Self.hoursLabel(minutes: thisWeek.totalMinutes),
                     label: "in meetings this week",
                     sub: lastWeek.totalMinutes > 0
                        ? "last week \(Self.hoursLabel(minutes: lastWeek.totalMinutes))"
                        : nil)
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

    /// "47m" under an hour, "3h 12m" above — zero-minute hours stay clean ("2h").
    static func hoursLabel(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total < 60 { return "\(total)m" }
        let (h, m) = (total / 60, total % 60)
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
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
                        .font(Dorado.barlowBold(15)).foregroundStyle(Dorado.midnight)
                    ForEach(suggestions) { suggestion in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(suggestion.displayName)
                                    .font(Dorado.barlowBold(15))
                                    .foregroundStyle(Dorado.midnight)
                                Text(kindLabel(suggestion.kind))
                                    .font(Dorado.roboto(11, .medium))
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Dorado.doradoTint)
                                    .foregroundStyle(Dorado.grey800)
                                    .clipShape(Capsule())
                                Spacer()
                            }
                            Text(suggestion.rationale)
                                .font(Dorado.roboto(13)).foregroundStyle(Dorado.grey800)
                            Text(suggestion.evidence)
                                .font(Dorado.roboto(12)).foregroundStyle(Dorado.grey500)
                            // What the Apply button concretely does — the
                            // rationale says why, this says what changes.
                            Text(applyEffect(suggestion.kind))
                                .font(Dorado.roboto(12)).foregroundStyle(Dorado.grey600)
                            HStack(spacing: 10) {
                                Button("Apply") {
                                    if let settings {
                                        RubricAdvisor.approve(suggestion, settings: settings)
                                        suggestions = RubricAdvisor.pending()
                                    }
                                }
                                .buttonStyle(DoradoOutlineButtonStyle())
                                .disabled(settings == nil)

                                Button("Dismiss") {
                                    RubricAdvisor.dismiss(suggestion, sessions: sessions)
                                    suggestions = RubricAdvisor.pending()
                                }
                                .buttonStyle(.plain)
                                .font(Dorado.roboto(13))
                                .foregroundStyle(Dorado.grey500)
                            }
                            .padding(.top, 4)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Dorado.warmSurface))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Dorado.warmBorder, lineWidth: 1))
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
        case .addSignal: return "new signal"
        }
    }

    private func applyEffect(_ kind: RubricSuggestion.Kind) -> String {
        switch kind {
        case .disable:
            return "Apply turns this signal off — it stops firing entirely."
        case .raiseCooldown:
            return "Apply keeps it just as sensitive but waits 50% longer between nudges — fewer repeats per meeting."
        case .moreSensitive:
            return "Apply lowers its threshold a little, so it fires a bit earlier."
        case .addSignal:
            return "Apply adds it to what the coach watches live — nudges can fire for it next call."
        }
    }

    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Focus").font(Dorado.barlowBold(15)).foregroundStyle(Dorado.midnight)
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
                    Text("Top patterns").font(Dorado.barlowBold(15)).foregroundStyle(Dorado.midnight)
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
        let points = sessions.compactMap { s in
            s.talkShare.map { (x: s.date.timeIntervalSinceReferenceDate, share: $0) }
        }
        return Group {
            if points.count >= 3 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Talk share by session").font(Dorado.barlowBold(15)).foregroundStyle(Dorado.midnight)
                    ShareTrendLine(points: points, showDots: true)
                        .frame(height: 60)
                }
            }
        }
    }

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Recent sessions").font(Dorado.barlowBold(15)).foregroundStyle(Dorado.midnight)
            ForEach(sessions.suffix(6).reversed()) { session in
                HStack {
                    if let title = session.title {
                        Text(title).font(.caption).lineLimit(1)
                        Text(session.date, style: .date)
                            .font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        Text(session.date, style: .date).font(.caption)
                    }
                    Text(session.durationFormatted)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let share = session.talkShare {
                        Text("you \(Int(share * 100))%")
                            .font(.caption2)
                            .foregroundStyle(share > TalkStats.warnShare ? .orange : .secondary)
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
                .font(Dorado.barlowXBold(22))
                .foregroundStyle(Dorado.midnight)
            Text(label)
                .font(Dorado.roboto(11))
                .foregroundStyle(Dorado.grey600)
            if let sub {
                Text(sub)
                    .font(Dorado.roboto(11))
                    .foregroundStyle(Dorado.grey400)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Dorado.border, lineWidth: 1))
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

