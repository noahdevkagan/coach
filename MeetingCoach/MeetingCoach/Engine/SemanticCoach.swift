import Foundation

/// Tier-2 semantic coaching: a low-frequency local-LLM pass over the recent
/// conversation, catching rubric signals that keyword heuristics can't —
/// alignment reached, buried signal, hedge not pinned, no decision named.
///
/// Runs async on its own heartbeat and never blocks the deterministic tier-1
/// signals. Everything stays on 127.0.0.1 (OllamaClient enforces loopback).
@MainActor
final class SemanticCoach {

    /// Seconds between LLM passes.
    static let heartbeatSeconds: TimeInterval = 60
    /// Semantic calls must earn the interruption — drop anything below this.
    static let confidenceThreshold = 0.75
    /// Per-signal cooldown so one theme doesn't nag repeatedly.
    static let perTypeCooldown: TimeInterval = 240
    /// How much recent conversation the model sees (seconds).
    static let windowSeconds: TimeInterval = 180

    /// Hard cap per signal type per meeting — a chronically-true condition
    /// ("no decision yet" in an exploratory discussion) must not become a
    /// drumbeat. Backtest evidence: noDecision fired 12× in one advisory 1:1.
    static let maxFiresPerType: [NudgeType: Int] = [
        .noDecision: 2, .alignmentReached: 3, .buriedSignal: 3,
        .hedgeNotPinned: 3, .commitmentGap: 2,
    ]

    private let client: OllamaClient
    private var lastFiredByType: [NudgeType: TimeInterval] = [:]
    private var firesByType: [NudgeType: Int] = [:]
    /// Everything already nudged, echoed back to the (stateless) model so it
    /// stops re-reporting the same observation every pass.
    private var firedHistory: [(type: NudgeType, text: String)] = []
    private var isAnalyzing = false

    private static let signalMap: [String: NudgeType] = [
        "no_decision": .noDecision,
        "alignment_reached": .alignmentReached,
        "buried_signal": .buriedSignal,
        "hedge_not_pinned": .hedgeNotPinned,
        "commitment_escalation": .commitmentGap,
    ]

    init(model: String) {
        // Short timeout: a semantic call that arrives 2 minutes late is
        // stale coaching. Better to skip a beat than nudge about the past.
        client = OllamaClient(model: model, timeout: 45)
    }

    /// Analyze the recent window. Returns at most one high-confidence nudge.
    /// Skips (returns []) if a previous analysis is still in flight.
    ///
    /// The window is rendered at UTTERANCE granularity, not coalesced turns:
    /// a high-stakes aside ("…me thinking I'm just gonna leave the company…")
    /// drowns mid-paragraph in a 300-word turn wall, but the model catches it
    /// reliably when each spoken line stays on its own line (verified against
    /// a real missed moment: 0 calls on turn-walls, 0.9-confidence catch on
    /// line-per-utterance).
    func analyze(utterances: [Utterance], elapsed: TimeInterval, context: PreCallContext) async -> [Nudge] {
        guard !isAnalyzing else { return [] }

        let windowStart = elapsed - Self.windowSeconds
        let window = utterances.filter { $0.t >= windowStart }
        // A meaningful pass needs real back-and-forth to judge.
        guard window.count >= 8 else { return [] }

        isAnalyzing = true
        defer { isAnalyzing = false }

        let (system, user) = Self.buildPrompt(
            window: window, elapsed: elapsed, context: context, alreadyFired: firedHistory
        )
        let raw: String
        do {
            raw = try await client.complete(system: system, user: user)
        } catch {
            mclog("[Semantic] LLM error: \(error.localizedDescription)")
            return []
        }

        let calls = Self.parseCalls(raw)
        mclog("[Semantic] \(calls.count) raw calls from model")

        // Gate: confidence, per-type cooldown, per-type session cap,
        // no near-duplicate of an earlier nudge, best-one-only.
        let eligible = calls
            .filter { $0.confidence >= Self.confidenceThreshold }
            .filter { call in
                let last = lastFiredByType[call.type] ?? -.infinity
                return elapsed - last >= Self.perTypeCooldown
            }
            .filter { call in
                firesByType[call.type, default: 0] < Self.maxFiresPerType[call.type, default: 3]
            }
            .filter { call in
                // Same-type nudge with heavily overlapping content = repeat.
                let words = TextAnalysis.contentWords(call.text)
                return !firedHistory.contains {
                    $0.type == call.type
                        && TextAnalysis.jaccard(words, TextAnalysis.contentWords($0.text)) >= 0.5
                }
            }
            .sorted { $0.confidence > $1.confidence }

        guard let best = eligible.first else { return [] }
        lastFiredByType[best.type] = elapsed
        firesByType[best.type, default: 0] += 1
        firedHistory.append((best.type, best.text))
        return [Nudge(
            id: UUID(),
            type: best.type,
            text: best.text,
            urgency: .med,
            timestamp: elapsed
        )]
    }

    func reset() {
        lastFiredByType = [:]
        firesByType = [:]
        firedHistory = []
    }

    // MARK: - Prompt

    private static func buildPrompt(
        window: [Utterance], elapsed: TimeInterval, context: PreCallContext,
        alreadyFired: [(type: NudgeType, text: String)]
    ) -> (system: String, user: String) {
        let system = """
        You are a real-time meeting coach watching a live transcript. You look ONLY for these five signals:

        1. no_decision — a clear question or topic has been open for many minutes and nobody has named a decision, an owner, and a date.
        2. alignment_reached — two or more people have stated compatible positions on the open question, but the discussion keeps going instead of closing it.
        3. buried_signal — a high-stakes statement (a number miss, churn, a named risk, someone hinting at quitting, a deadline slip) was mentioned and the conversation moved past it without engaging.
        4. hedge_not_pinned — a commitment was stated as a range or with soft language ("in a few weeks", "we should be able to") and was not pinned to a concrete date or number.
        5. commitment_escalation — the user's own commitment grew substantially mid-discussion ("two calls" becoming "a call a day") without anyone acknowledging the change in scope.

        Rules:
        - Report a signal ONLY with strong evidence in the transcript. Silence is the correct output most of the time.
        - Never report a signal for something the speakers already resolved.
        - "nudge" is the short coaching line shown to the user mid-meeting: max 8 words, imperative, concrete.

        Respond with ONLY a JSON array, no other text. Each item:
        {"signal": "<one of: no_decision, alignment_reached, buried_signal, hedge_not_pinned, commitment_escalation>", "nudge": "<max 8 words>", "confidence": <0.0-1.0>}

        Return [] if nothing qualifies (this is the usual case).
        """

        var userParts: [String] = []
        if !context.meetingGoal.isEmpty {
            userParts.append("Meeting goal: \(context.meetingGoal)")
        }
        switch context.effectiveMeetingType {
        case .oneOnOne:
            userParts.append("Meeting type: advisory 1:1 — exploratory discussion is expected here. Flag no_decision ONLY when a concrete commitment was explicitly being negotiated and left open.")
        case .salesCall:
            userParts.append("Meeting type: sales/deal call — hedged commitments and buried objections matter most.")
        case .teamMeeting:
            userParts.append("Meeting type: team meeting — decisions need owners and dates.")
        case .general:
            break
        }
        if !alreadyFired.isEmpty {
            userParts.append("Already nudged this meeting (do NOT re-report these or minor variations of them):\n"
                + alreadyFired.map { "- \($0.type.rawValue): \($0.text)" }.joined(separator: "\n"))
        }
        userParts.append("Elapsed: \(Int(elapsed / 60)) minutes.")
        userParts.append("Recent conversation (You = the user being coached):")
        userParts.append(window.map { u in
            let who = u.isYou ? "You" : (u.speaker == "Meeting" ? "Meeting" : "Them")
            return "[\(u.formattedTime)] \(who): \(u.text)"
        }.joined(separator: "\n"))
        return (system, userParts.joined(separator: "\n\n"))
    }

    // MARK: - Parsing

    private struct SemanticCall {
        let type: NudgeType
        let text: String
        let confidence: Double
    }

    private static func parseCalls(_ raw: String) -> [SemanticCall] {
        // Models wrap JSON in prose/code fences; extract the outermost array.
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"),
              start < end else { return [] }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return items.compactMap { item in
            guard let signal = item["signal"] as? String,
                  let type = signalMap[signal],
                  let text = item["nudge"] as? String,
                  !text.isEmpty
            else { return nil }
            let confidence = (item["confidence"] as? Double)
                ?? (item["confidence"] as? Int).map(Double.init)
                ?? 0
            // Enforce the 8-word budget defensively.
            let words = text.split(separator: " ")
            let clipped = words.count > 8 ? words.prefix(8).joined(separator: " ") : text
            return SemanticCall(type: type, text: clipped, confidence: confidence)
        }
    }
}
