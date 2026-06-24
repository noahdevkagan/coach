import Foundation

/// Append-only debug log at /tmp/mc_debug.log
func mclog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    NSLog("%@", msg)
    if let data = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: "/tmp/mc_debug.log") {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: "/tmp/mc_debug.log", contents: data)
        }
    }
}

/// Port of coach.py — the coaching core. Sends triggers to the LLM, applies
/// confidence gates, dedup cooldown. Nag control lives here.
final class CoachEngine: @unchecked Sendable {
    let rubric: Rubric
    let client: OllamaClient
    let dedupCooldown: TimeInterval
    let useMock: Bool
    private let systemPrompt: String
    private var lastFired: [String: TimeInterval] = [:]

    init(rubric: Rubric, client: OllamaClient,
         dedupCooldown: TimeInterval = 120, useMock: Bool = false) {
        self.rubric = rubric
        self.client = client
        self.dedupCooldown = dedupCooldown
        self.useMock = useMock
        // Load saved training examples for few-shot calibration
        let examples = TrainingStore.load()
        self.systemPrompt = PromptBuilder.buildSystem(rubric: rubric, trainingExamples: examples)
        if !examples.isEmpty {
            mclog("[Coach] System prompt includes \(examples.count) training example(s)")
        }
    }

    func onTrigger(_ trigger: Trigger) async throws -> [CoachingCall] {
        let userPrompt = PromptBuilder.buildUser(
            window: trigger.window, summary: trigger.summary, now: trigger.now)

        mclog("[Coach] Trigger at \(String(format: "%.0f", trigger.now))s with \(trigger.window.count) utterances, \(rubric.signals.count) signals")
        mclog("[Coach] USER PROMPT:\n\(userPrompt)")

        let raw: String
        if useMock {
            raw = MockProvider.complete(user: userPrompt)
        } else {
            raw = try await client.complete(system: systemPrompt, user: userPrompt)
        }

        mclog("[Coach] LLM raw response (\(raw.count) chars): \(raw.prefix(800))")

        let parsed = extractJSONArray(raw)
        mclog("[Coach] Parsed \(parsed.count) items from JSON")

        var kept: [CoachingCall] = []
        for item in parsed {
            mclog("[Coach]   Item keys: \(item.keys.sorted().joined(separator: ", "))")
            guard let sigId = item["signal_id"] as? String else {
                mclog("[Coach]   Skipped item — no signal_id key")
                continue
            }
            guard let sig = rubric.signal(byId: sigId) else {
                mclog("[Coach]   Skipped '\(sigId)' — not in rubric (have: \(rubric.signals.map(\.id).joined(separator: ", ")))")
                continue
            }
            let conf = (item["confidence"] as? Double)
                ?? (item["confidence"] as? NSNumber)?.doubleValue ?? 0
            let floor = max(sig.minConfidence, rubric.output.minConfidenceToShow)
            if conf < floor {
                mclog("[Coach]   Skipped '\(sigId)' — confidence \(conf) < floor \(floor)")
                continue
            }

            if let last = lastFired[sig.id], trigger.now - last < dedupCooldown {
                mclog("[Coach]   Skipped '\(sigId)' — dedup cooldown")
                continue
            }

            let evidence = item["evidence"] as? String ?? ""
            let nudge = (item["nudge"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sig.nudge
            kept.append(CoachingCall(
                t: trigger.now, signalId: sig.id, confidence: conf,
                evidence: evidence, nudge: nudge, reason: trigger.reason))
            mclog("[Coach]   KEPT '\(sigId)' confidence=\(conf)")
        }

        kept.sort { $0.confidence > $1.confidence }
        kept = Array(kept.prefix(rubric.output.maxCallsPerTrigger))
        for call in kept {
            lastFired[call.signalId] = call.t
        }
        mclog("[Coach] Returning \(kept.count) coaching calls")
        return kept
    }

    // MARK: - JSON extraction (port of coach.py:_extract_json_array)

    private func extractJSONArray(_ raw: String) -> [[String: Any]] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip markdown fences
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(
                of: #"^```[a-zA-Z]*\n?|\n?```$"#,
                with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let data = text.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            mclog("[Coach] JSON direct parse OK: \(arr.count) items")
            return arr
        }
        mclog("[Coach] JSON direct parse failed, trying regex fallback on: \(text.prefix(200))")
        // Fallback: find first [...] in the text
        let regex = try? NSRegularExpression(pattern: #"\[[\s\S]*\]"#)
        let nsText = text as NSString
        if let match = regex?.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let sub = nsText.substring(with: match.range)
            if let data = sub.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                mclog("[Coach] JSON regex fallback OK: \(arr.count) items")
                return arr
            }
            mclog("[Coach] JSON regex fallback FAILED to parse: \(sub.prefix(200))")
        } else {
            mclog("[Coach] No JSON array [...] found in response at all")
        }
        return []
    }
}

// MARK: - Mock provider (port of llm.py:MockProvider)

enum MockProvider {
    static func complete(user: String) -> String {
        let text = user.lowercased()
        var calls: [[String: Any]] = []

        func add(_ signalId: String, _ confidence: Double, _ evidence: String, _ nudge: String) {
            calls.append(["signal_id": signalId, "confidence": confidence,
                          "evidence": evidence, "nudge": nudge])
        }

        let alignPhrases = ["i think we agree", "sounds like we agree",
                            "we're aligned", "i'm on board", "same page",
                            "fully in agreement", "i agree"]
        if alignPhrases.contains(where: { text.contains($0) }) {
            add("alignment_reached_still_talking", 0.78,
                "participants signalling agreement", "They converged. Close it.")
        }
        if ["circle back", "revisit", "as we discussed", "go back to", "reopen"]
            .contains(where: { text.contains($0) }) {
            add("reopening_closed_thread", 0.72,
                "a settled topic resurfacing", "This was settled. On purpose?")
        }
        if ["by end of quarter", "sometime next", "roughly", "ballpark",
            "a few weeks", "ish", "should be able to", "maybe", "probably"]
            .contains(where: { text.contains($0) }) {
            add("hedge_not_pinned", 0.83,
                "commitment stated as a range", "That was a range. Pin the date.")
        }
        if ["churn", "missed", "down ", "risk", "behind plan",
            "miss the number", "lost the deal", "gap"]
            .contains(where: { text.contains($0) }) {
            add("buried_signal_ignored", 0.70,
                "a high-stakes number/risk mentioned", "That was the headline. Don't move on.")
        }
        if ["who owns", "no owner", "let's decide", "what do we do",
            "still open", "haven't decided"]
            .contains(where: { text.contains($0) }) {
            add("no_decision_owner_date", 0.68,
                "open question with no owner/date", "Nothing named. Decide it or park it.")
        }

        let limited = Array(calls.prefix(3))
        if let data = try? JSONSerialization.data(withJSONObject: limited),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "[]"
    }
}
