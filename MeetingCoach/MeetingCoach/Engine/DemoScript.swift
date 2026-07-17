import Foundation

/// The bundled demo meeting: a synthetic transcript replayed through the real
/// signal pipeline, plus pre-scripted "AI" nudges injected at fixed
/// timestamps. The demo therefore needs no mic, no permissions, no model —
/// it's the first-launch proof that coaching works, inside a minute.
struct DemoScript {
    struct ScriptedNudge: Decodable {
        let t: TimeInterval
        let type: String
        let text: String
        let urgency: String

        var nudge: Nudge? {
            guard let type = NudgeType(rawValue: type),
                  let urgency = NudgeUrgency(rawValue: urgency) else { return nil }
            return Nudge(id: UUID(), type: type, text: text, urgency: urgency, timestamp: t)
        }
    }

    let utterances: [Utterance]
    let scriptedNudges: [ScriptedNudge]

    /// Scripted duration: last event plus a beat to let it land.
    var duration: TimeInterval {
        let lastU = utterances.last?.endT ?? 0
        let lastN = scriptedNudges.map(\.t).max() ?? 0
        return max(lastU, lastN) + 4
    }

    static func loadBundled() -> DemoScript? {
        guard let txtURL = Bundle.main.url(forResource: "demo_meeting", withExtension: "txt"),
              let text = try? String(contentsOf: txtURL, encoding: .utf8) else {
            mclog("[Demo] demo_meeting.txt missing from bundle")
            return nil
        }
        let utterances = TranscriptParser.parse(text)
        guard !utterances.isEmpty else {
            mclog("[Demo] demo_meeting.txt parsed to zero utterances")
            return nil
        }

        var nudges: [ScriptedNudge] = []
        if let jsonURL = Bundle.main.url(forResource: "demo_nudges", withExtension: "json"),
           let data = try? Data(contentsOf: jsonURL),
           let parsed = try? JSONDecoder().decode([ScriptedNudge].self, from: data) {
            nudges = parsed.sorted { $0.t < $1.t }
        }
        return DemoScript(utterances: utterances, scriptedNudges: nudges)
    }
}
