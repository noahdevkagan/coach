import Foundation

/// A proposed structural change to the active rubric, backed by evidence
/// from real sessions. Nothing here applies itself: suggestions surface on
/// the dashboard and change the rubric only when the user approves —
/// bounded adaptive auto-tuning stays automatic, structure never is.
struct RubricSuggestion: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case disable          // stop watching this signal
        case raiseCooldown    // keep it, but fire less often
        case moreSensitive    // it's earning "Useful" — fire a bit sooner
    }
    enum Status: String, Codable { case pending, dismissed, applied }

    var id = UUID()
    let kind: Kind
    /// NudgeType.rawValue, or "custom:<id>" for rubric-defined signals.
    let signalKey: String
    let rationale: String
    let evidence: String
    var status: Status = .pending
    var createdAt = Date()
    /// Evidence size when created/last dismissed — a dismissed suggestion
    /// stays suppressed until evidence doubles or ten sessions pass.
    var evidenceRatedCount = 0
    var sessionCountAtCreation = 0

    var displayName: String {
        if signalKey.hasPrefix("custom:") {
            return signalKey.dropFirst("custom:".count)
                .split(separator: "_").map(\.capitalized).joined(separator: " ")
        }
        return NudgeType(rawValue: signalKey)?.displayName ?? signalKey
    }
}

/// Deterministic rules first: the advisor mines saved-session feedback and
/// adaptive-threshold state for signals that earned a structural change.
/// Deterministic ⇒ golden-testable; an LLM pass can layer on later.
enum RubricAdvisor {

    // Rule thresholds
    static let minRated = 5
    static let minSessions = 3
    static let wrongRate = 0.6
    static let annoyingRate = 0.6
    static let usefulRate = 0.8
    /// The adaptive clamp ceiling — pinned here for 3+ sessions and still
    /// firing means bounded auto-tuning has given up on this signal.
    static let adaptiveCeiling = 2.0

    /// Aggregated per-signal evidence across sessions. Plain data so the
    /// rules stay a pure, testable function.
    struct SignalEvidence {
        let key: String
        var rated = 0
        var wrong = 0
        var annoying = 0
        var useful = 0
        var sessionsWithSignal = 0
        var adaptiveMultiplier = 1.0
        var firedInRecentSessions = false
    }

    // MARK: - Evidence

    static func evidence(from sessions: [SessionSummary]) -> [SignalEvidence] {
        var byKey: [String: SignalEvidence] = [:]
        let recent = sessions.suffix(3)

        for session in sessions {
            for (key, count) in session.nudgeKeyCounts where count > 0 {
                var e = byKey[key] ?? SignalEvidence(key: key)
                e.sessionsWithSignal += 1
                if let feedback = session.feedbackByKey[key] {
                    e.rated += feedback.values.reduce(0, +)
                    e.wrong += feedback[.wrong] ?? 0
                    e.annoying += feedback[.annoying] ?? 0
                    e.useful += feedback[.useful] ?? 0
                }
                byKey[key] = e
            }
        }
        for key in byKey.keys {
            byKey[key]!.adaptiveMultiplier = AdaptiveThresholds.multiplier(forKey: key)
            byKey[key]!.firedInRecentSessions = recent.contains { ($0.nudgeKeyCounts[key] ?? 0) > 0 }
        }
        return byKey.values.sorted { $0.key < $1.key }
    }

    // MARK: - Rules (pure)

    /// The strongest applicable proposal for one signal, or nil.
    static func proposal(for e: SignalEvidence) -> (kind: RubricSuggestion.Kind, rationale: String, evidence: String)? {
        guard e.sessionsWithSignal >= minSessions else { return nil }
        let isCustom = e.key.hasPrefix("custom:")

        if e.rated >= minRated {
            let total = Double(e.rated)
            if Double(e.wrong) / total >= wrongRate {
                return (.disable,
                        "This signal is mostly firing on the wrong moments.",
                        "You rated \(e.wrong) of \(e.rated) \"Wrong\" across \(e.sessionsWithSignal) sessions.")
            }
            if Double(e.annoying) / total >= annoyingRate {
                // Customs have no cooldown knob in the rubric — disable them.
                return (isCustom ? .disable : .raiseCooldown,
                        isCustom
                        ? "This custom signal reads as noise more often than help."
                        : "Right idea, too often — a longer cooldown keeps it useful.",
                        "You rated \(e.annoying) of \(e.rated) \"Meh\" across \(e.sessionsWithSignal) sessions.")
            }
            if Double(e.useful) / total >= usefulRate, !isCustom {
                return (.moreSensitive,
                        "This one keeps earning \"Useful\" — it can fire a little sooner.",
                        "You rated \(e.useful) of \(e.rated) \"Useful\" across \(e.sessionsWithSignal) sessions.")
            }
        }

        // Adaptive tuning pinned at its ceiling and the signal still fires:
        // bounded auto-tuning can't fix it, so propose the structural cut.
        if e.adaptiveMultiplier >= adaptiveCeiling - 0.01, e.firedInRecentSessions {
            return (.disable,
                    "Feedback pushed this signal's sensitivity to its floor and it still fires.",
                    "Learned sensitivity is at its \(String(format: "%.1fx", adaptiveCeiling)) limit after \(e.sessionsWithSignal) sessions.")
        }
        return nil
    }

    // MARK: - Refresh (merge rules with stored state)

    @discardableResult
    static func refresh(sessions: [SessionSummary]) -> [RubricSuggestion] {
        var stored = loadAll()

        for e in evidence(from: sessions) {
            guard let (kind, rationale, evidenceText) = proposal(for: e) else { continue }

            if let idx = stored.firstIndex(where: { $0.signalKey == e.key && $0.kind == kind }) {
                switch stored[idx].status {
                case .pending, .applied:
                    continue
                case .dismissed:
                    // Re-propose only when the evidence has genuinely grown.
                    let sessionsSince = sessions.count - stored[idx].sessionCountAtCreation
                    if e.rated >= max(1, stored[idx].evidenceRatedCount) * 2 || sessionsSince >= 10 {
                        var s = stored[idx]
                        s.status = .pending
                        s.evidenceRatedCount = e.rated
                        s.sessionCountAtCreation = sessions.count
                        stored[idx] = s
                    }
                }
            } else {
                stored.append(RubricSuggestion(
                    kind: kind, signalKey: e.key,
                    rationale: rationale, evidence: evidenceText,
                    evidenceRatedCount: e.rated,
                    sessionCountAtCreation: sessions.count))
            }
        }

        saveAll(stored)
        return stored
    }

    static func pending() -> [RubricSuggestion] {
        loadAll().filter { $0.status == .pending }
    }

    static func dismiss(_ suggestion: RubricSuggestion, sessionCount: Int) {
        update(suggestion) {
            $0.status = .dismissed
            $0.sessionCountAtCreation = sessionCount
        }
    }

    static func markApplied(_ suggestion: RubricSuggestion) {
        update(suggestion) { $0.status = .applied }
    }

    private static func update(_ suggestion: RubricSuggestion, _ mutate: (inout RubricSuggestion) -> Void) {
        var stored = loadAll()
        guard let idx = stored.firstIndex(where: { $0.id == suggestion.id }) else { return }
        mutate(&stored[idx])
        saveAll(stored)
    }

    // MARK: - Persistence (suggestions.json in Application Support)

    static func loadAll() -> [RubricSuggestion] {
        guard let data = try? Data(contentsOf: AppSupport.suggestionsURL),
              let list = try? JSONDecoder().decode([RubricSuggestion].self, from: data)
        else { return [] }
        return list
    }

    static func saveAll(_ suggestions: [RubricSuggestion]) {
        AppSupport.ensureLayout()
        if let data = try? JSONEncoder().encode(suggestions) {
            try? data.write(to: AppSupport.suggestionsURL, options: .atomic)
        }
    }
}
