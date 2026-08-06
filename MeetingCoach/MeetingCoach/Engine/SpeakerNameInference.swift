import Foundation

/// A proposed real name for a diarized speaker label, surfaced in the UI as
/// a one-tap confirmation. Confirming routes through the full rename path
/// (transcript, live timeline, saved voice profile).
struct SpeakerNameSuggestion: Identifiable, Sendable {
    let id = UUID()
    let label: String       // "Them 1", "Speaker 2", "Them"
    let name: String        // "Sarah"
    let confidence: Double
    var key: String { "\(label)→\(name.lowercased())" }
}

/// Infers speakers' real names from transcript evidence — people say each
/// other's names constantly ("thanks Sarah", "this is William from finance").
/// A low-frequency local-LLM pass over the intro window plus recent talk;
/// runs only while unnamed labels exist. Suggestions are never auto-applied:
/// a wrong name silently attached to a voice would poison future sessions,
/// so the user always confirms.
@MainActor
final class SpeakerNameInference {

    /// Minimum seconds between LLM passes (intro evidence doesn't churn).
    static let cooldown: TimeInterval = 120
    static let confidenceThreshold = 0.8
    /// Names come from a small local model — keep the sanity bar high.
    private static let maxNameLength = 30

    /// Labels eligible for naming: diarizer slot labels and the undiarized
    /// far-side base label. Never "You".
    private static let unnamedPattern = #/^(Them|Speaker|Meeting)( \d+)?$/#

    private let client: OllamaClient
    private var lastRun: TimeInterval = -.infinity
    private var isAnalyzing = false

    init(model: String) {
        // 4096 ctx, matching SemanticCoach — in-call requests share one
        // runner config so no reload happens between the two callers.
        client = OllamaClient(model: model, timeout: 45, numCtx: 4096)
    }

    /// Propose names for unnamed speaker labels in the transcript.
    /// `rejected` keys ("Them 1→sarah") are never re-suggested.
    func analyze(utterances: [Utterance], elapsed: TimeInterval,
                 rejected: Set<String>) async -> [SpeakerNameSuggestion] {
        guard !isAnalyzing, elapsed - lastRun >= Self.cooldown else { return [] }

        let unnamedLabels = Set(utterances.map(\.speaker).filter {
            $0.wholeMatch(of: Self.unnamedPattern) != nil
        })
        guard !unnamedLabels.isEmpty else { return [] }

        // Names concentrate in introductions — always show the model the
        // opening minutes, plus the recent window for late joiners.
        let intro = utterances.prefix { $0.t < 180 }
        let recent = utterances.drop { $0.t < elapsed - 240 }
        var window = Array(intro)
        if let firstRecent = recent.first,
           let lastIntro = intro.last, firstRecent.t > lastIntro.t {
            window.append(contentsOf: recent)
        } else if intro.isEmpty {
            window = Array(recent)
        }
        guard window.count >= 6 else { return [] }

        isAnalyzing = true
        defer { isAnalyzing = false }
        lastRun = elapsed

        // Names already in use (renamed/enrolled speakers) must not be
        // proposed again for someone else.
        let takenNames = Set(utterances.map(\.speaker)
            .filter { $0.wholeMatch(of: Self.unnamedPattern) == nil && $0 != "You" }
            .map { $0.lowercased() })

        let system = """
        You identify meeting participants' real names from a transcript. Speakers are labeled with placeholders (\(unnamedLabels.sorted().joined(separator: ", "))). "You" is the user being coached — never rename them.

        Find real first names ONLY when the transcript gives direct evidence:
        - a speaker introduces themself ("Hi, this is Priya")
        - someone addresses a person by name and that labeled speaker responds

        Respond with ONLY a JSON array, no other text. Each item:
        {"label": "<placeholder label>", "name": "<first name, properly capitalized>", "confidence": <0.0-1.0>}

        Return [] when the evidence is weak (this is the usual case). Never guess from context or topic.
        """
        let user = "Transcript:\n" + window.map {
            "[\($0.formattedTime)] \($0.speaker): \($0.text)"
        }.joined(separator: "\n")

        let raw: String
        do {
            raw = try await client.complete(system: system, user: user)
        } catch {
            mclog("[Names] LLM error: \(error.localizedDescription)")
            return []
        }

        return parse(raw, unnamedLabels: unnamedLabels,
                     takenNames: takenNames, rejected: rejected)
    }

    private func parse(_ raw: String, unnamedLabels: Set<String>,
                       takenNames: Set<String>, rejected: Set<String>) -> [SpeakerNameSuggestion] {
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        var seenNames = takenNames
        var result: [SpeakerNameSuggestion] = []
        for item in items {
            guard let label = item["label"] as? String,
                  let rawName = item["name"] as? String else { continue }
            let confidence = (item["confidence"] as? Double)
                ?? (item["confidence"] as? Int).map(Double.init) ?? 0
            let name = rawName.trimmingCharacters(in: .whitespaces)

            guard confidence >= Self.confidenceThreshold,
                  unnamedLabels.contains(label),
                  looksLikeName(name),
                  !seenNames.contains(name.lowercased())
            else { continue }
            let suggestion = SpeakerNameSuggestion(label: label, name: name, confidence: confidence)
            guard !rejected.contains(suggestion.key) else { continue }
            seenNames.insert(name.lowercased())
            result.append(suggestion)
        }
        return result
    }

    /// 1–2 capitalized alphabetic words — defends against a small model
    /// emitting sentences, placeholders, or the literal label back.
    private func looksLikeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= Self.maxNameLength,
              name.wholeMatch(of: Self.unnamedPattern) == nil else { return false }
        let words = name.split(separator: " ")
        guard (1...2).contains(words.count) else { return false }
        return words.allSatisfy { w in
            w.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" } && w.first!.isUppercase
        }
    }
}
