import Foundation

/// A rubric-defined signal the semantic coach watches beyond its built-in
/// set. Plain type (not Rubric) so bench/test harnesses can compile this
/// file standalone, without the YAML layer.
struct CustomSemanticSignal: Sendable {
    let id: String            // snake_case rubric id, e.g. "rambling_intro"
    let name: String          // display name, e.g. "Rambling Intro"
    let description: String   // what the model should look for
}

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
        .hedgeNotPinned: 3, .commitmentGap: 2, .questionParked: 2,
    ]
    /// Custom rubric signals ship conservative until they earn trust.
    static let maxFiresPerCustom = 2

    /// One built-in semantic signal: prompt id, nudge type, and the
    /// definition line the model sees.
    private struct SignalDef {
        let id: String
        let type: NudgeType
        let definition: String
    }

    private static let builtinDefs: [SignalDef] = [
        SignalDef(id: "no_decision", type: .noDecision,
                  definition: "a clear question or topic has been open for many minutes and nobody has named a decision, an owner, and a date."),
        SignalDef(id: "alignment_reached", type: .alignmentReached,
                  definition: "two or more people have stated compatible positions on the open question, but the discussion keeps going instead of closing it."),
        SignalDef(id: "buried_signal", type: .buriedSignal,
                  definition: "a high-stakes statement (a number miss, churn, a named risk, someone hinting at quitting, a deadline slip) was mentioned and the conversation moved past it without engaging."),
        SignalDef(id: "hedge_not_pinned", type: .hedgeNotPinned,
                  definition: "a commitment was stated as a range or with soft language (\"in a few weeks\", \"we should be able to\") and was not pinned to a concrete date or number."),
        SignalDef(id: "commitment_escalation", type: .commitmentGap,
                  definition: "the user's own commitment grew substantially mid-discussion (\"two calls\" becoming \"a call a day\") without anyone acknowledging the change in scope."),
        SignalDef(id: "question_parked", type: .questionParked,
                  definition: "the user has asked essentially the same substantive question more than twice (possibly in different words) and it keeps getting deflected or parked instead of answered."),
    ]

    private let client: OllamaClient
    /// Built-in semantic signals still enabled by the active rubric.
    private let activeDefs: [SignalDef]
    /// Rubric-defined signals, keyed by their snake_case id.
    private let customSignals: [String: CustomSemanticSignal]
    private var lastFiredByKey: [String: TimeInterval] = [:]
    private var firesByKey: [String: Int] = [:]
    /// Everything already nudged, echoed back to the (stateless) model so it
    /// stops re-reporting the same observation every pass.
    private var firedHistory: [(key: String, label: String, text: String)] = []
    private var isAnalyzing = false

    init(model: String, tuning: RubricTuning = [:], customSignals: [CustomSemanticSignal] = []) {
        // Short timeout: a semantic call that arrives 2 minutes late is
        // stale coaching. Better to skip a beat than nudge about the past.
        client = OllamaClient(model: model, timeout: 45)
        activeDefs = Self.builtinDefs.filter { tuning[$0.type.rawValue]?.enabled ?? true }
        self.customSignals = Dictionary(uniqueKeysWithValues: customSignals.map { ($0.id, $0) })
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
        guard !activeDefs.isEmpty || !customSignals.isEmpty else { return [] }

        let windowStart = elapsed - Self.windowSeconds
        let window = utterances.filter { $0.t >= windowStart }
        // A meaningful pass needs real back-and-forth to judge.
        guard window.count >= 8 else { return [] }

        isAnalyzing = true
        defer { isAnalyzing = false }

        let (system, user) = buildPrompt(
            window: window, elapsed: elapsed, context: context
        )
        let raw: String
        do {
            raw = try await client.complete(system: system, user: user)
        } catch {
            mclog("[Semantic] LLM error: \(error.localizedDescription)")
            return []
        }

        let calls = parseCalls(raw)
        mclog("[Semantic] \(calls.count) raw calls from model")

        // Gate: confidence, per-signal cooldown, per-signal session cap,
        // no near-duplicate of an earlier nudge, best-one-only.
        let eligible = calls
            .filter { $0.confidence >= Self.confidenceThreshold }
            .filter { call in
                let last = lastFiredByKey[call.key] ?? -.infinity
                return elapsed - last >= Self.perTypeCooldown
            }
            .filter { call in
                firesByKey[call.key, default: 0] < maxFires(for: call)
            }
            .filter { call in
                // Same-signal nudge with heavily overlapping content = repeat.
                let words = TextAnalysis.contentWords(call.text)
                return !firedHistory.contains {
                    $0.key == call.key
                        && TextAnalysis.jaccard(words, TextAnalysis.contentWords($0.text)) >= 0.5
                }
            }
            .sorted { $0.confidence > $1.confidence }

        guard let best = eligible.first else { return [] }
        lastFiredByKey[best.key] = elapsed
        firesByKey[best.key, default: 0] += 1
        firedHistory.append((best.key, best.label, best.text))
        return [Nudge(
            id: UUID(),
            type: best.type,
            text: best.text,
            urgency: .med,
            timestamp: elapsed,
            customId: best.customId,
            customName: best.customName
        )]
    }

    func reset() {
        lastFiredByKey = [:]
        firesByKey = [:]
        firedHistory = []
    }

    private func maxFires(for call: SemanticCall) -> Int {
        if call.type == .custom { return Self.maxFiresPerCustom }
        return Self.maxFiresPerType[call.type, default: 3]
    }

    // MARK: - Prompt

    private func buildPrompt(
        window: [Utterance], elapsed: TimeInterval, context: PreCallContext
    ) -> (system: String, user: String) {
        var defLines: [String] = []
        var ids: [String] = []
        var n = 1
        for def in activeDefs {
            defLines.append("\(n). \(def.id) — \(def.definition)")
            ids.append(def.id)
            n += 1
        }
        for custom in customSignals.values.sorted(by: { $0.id < $1.id }) {
            defLines.append("\(n). \(custom.id) — (user-defined) \(custom.description)")
            ids.append(custom.id)
            n += 1
        }

        let system = """
        You are a real-time meeting coach watching a live transcript. You look ONLY for these signals:

        \(defLines.joined(separator: "\n"))

        Rules:
        - Report a signal ONLY with strong evidence in the transcript. Silence is the correct output most of the time.
        - Never report a signal for something the speakers already resolved.
        - "nudge" is the short coaching line shown to the user mid-meeting: max 8 words, imperative, concrete.

        Respond with ONLY a JSON array, no other text. Each item:
        {"signal": "<one of: \(ids.joined(separator: ", "))>", "nudge": "<max 8 words>", "confidence": <0.0-1.0>}

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
        if !firedHistory.isEmpty {
            userParts.append("Already nudged this meeting (do NOT re-report these or minor variations of them):\n"
                + firedHistory.map { "- \($0.label): \($0.text)" }.joined(separator: "\n"))
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
        let customId: String?
        let customName: String?

        var key: String {
            if let customId { return "custom:\(customId)" }
            return type.rawValue
        }
        var label: String { customId ?? type.rawValue }
    }

    private func parseCalls(_ raw: String) -> [SemanticCall] {
        // Models wrap JSON in prose/code fences; extract the outermost array.
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"),
              start < end else { return [] }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        let builtinById = Dictionary(uniqueKeysWithValues: activeDefs.map { ($0.id, $0.type) })

        return items.compactMap { item in
            guard let signal = item["signal"] as? String,
                  let text = item["nudge"] as? String,
                  !text.isEmpty
            else { return nil }

            let type: NudgeType
            var customId: String?
            var customName: String?
            if let builtin = builtinById[signal] {
                type = builtin
            } else if let custom = customSignals[signal] {
                type = .custom
                customId = custom.id
                customName = custom.name
            } else {
                return nil
            }

            let confidence = (item["confidence"] as? Double)
                ?? (item["confidence"] as? Int).map(Double.init)
                ?? 0
            // Enforce the 8-word budget defensively.
            let words = text.split(separator: " ")
            let clipped = words.count > 8 ? words.prefix(8).joined(separator: " ") : text
            return SemanticCall(type: type, text: clipped, confidence: confidence,
                                customId: customId, customName: customName)
        }
    }
}
