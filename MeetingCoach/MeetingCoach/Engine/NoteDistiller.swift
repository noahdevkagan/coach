import Foundation

/// Turns free-form coaching notes — often pasted from another AI's post-call
/// analysis — into signals the coach can actually act on. TrainingStore's
/// keyword parser only catches notes that name signals ("watch my talk
/// time"); prose like "you keep selling after they've said yes" names
/// nothing and used to train nothing. The distiller asks the local model to
/// map such prose onto the built-in vocabulary where it fits, and to propose
/// new custom semantic signals for patterns the vocabulary doesn't cover.
/// Built-in matches feed training directly (same as a keyword hit); new
/// signals become dashboard suggestions the user approves into the rubric.
enum NoteDistiller {

    struct CustomProposal: Equatable {
        let id: String          // snake_case rubric signal id
        let description: String // what to watch for in a live transcript
        let nudge: String       // ≤ 8 words, imperative
        let evidence: String    // the line of the note it came from
    }

    struct Extraction {
        var builtin: [SignalExample] = []
        var custom: [CustomProposal] = []
        var isEmpty: Bool { builtin.isEmpty && custom.isEmpty }
    }

    /// The coachable built-in vocabulary with one-line glosses — ids alone
    /// mean nothing to the model. Positives included: notes praise wins too.
    private static let vocabulary: [(NudgeType, String)] = [
        (.talkTime, "the user talks too long in one stretch"),
        (.voiceShare, "the user dominates the meeting's overall airtime"),
        (.interruption, "the user cuts the other person off"),
        (.stackedQuestions, "the user asks several questions at once"),
        (.unansweredQuestion, "the other person's question goes unanswered"),
        (.missingDiscovery, "the user isn't asking questions"),
        (.repetitionLoop, "the same point gets re-argued without a decision"),
        (.nextSteps, "the meeting nears its end with no next steps"),
        (.goingQuiet, "the other person goes quiet or disengages"),
        (.yesMan, "the other person just agrees without conviction"),
        (.vagueAnswer, "a vague answer gets accepted without a follow-up"),
        (.overrun, "the meeting runs past its scheduled time"),
        (.questionParked, "the user's question gets deflected and never re-asked"),
        (.hedgeNotPinned, "a commitment stays soft — no firm date"),
        (.noDecision, "an open question closes with no decision, owner, or date"),
        (.buriedSignal, "an important statement gets passed over"),
        (.questionLanded, "a short open question got them talking (praise)"),
        (.reflectedBack, "the user says the other person's point back (praise)"),
        (.ownershipHanded, "the user hands the decision over cleanly (praise)"),
        (.refocused, "the user pulls a drifting room back on track (praise)"),
        (.commitmentLocked, "the user locks owner and date out loud (praise)"),
    ]

    static func prompt(note: String) -> (system: String, user: String) {
        let vocab = vocabulary
            .map { "- \($0.0.rawValue): \($0.1)" }
            .joined(separator: "\n")
        let system = """
        You convert post-call coaching feedback into signals a live meeting coach can watch for. The coach sees a rolling transcript and nudges the user in real time.

        Known signals:
        \(vocab)

        Read the feedback and respond with ONLY a JSON object, no other text:
        {"builtin": [{"signal": "<id from the list>", "evidence": "<the sentence of the feedback it comes from>", "nudge": "<max 8 words, imperative>"}],
         "custom": [{"id": "<short_snake_case>", "description": "<one sentence: the observable transcript pattern to watch for>", "nudge": "<max 8 words, imperative>", "evidence": "<the sentence of the feedback it comes from>"}]}

        Rules:
        - Use "builtin" whenever a known signal genuinely covers the pattern; "custom" only for patterns none of them cover.
        - At most 3 custom signals, and only ones detectable from what people SAY during a call — skip advice about preparation, mindset, or anything outside the meeting.
        - A custom description must describe the moment to catch ("after the other person agrees, the user keeps pitching"), not restate the advice.
        - Empty arrays are fine if the feedback teaches nothing watchable.
        """
        return (system, "Coaching feedback:\n\n\(note)")
    }

    /// Tolerant parse of the model's reply — pure and separately testable.
    /// Unknown builtin ids are dropped; custom ids are normalized to
    /// snake_case; entries missing their substance are skipped.
    static func parse(_ text: String) -> Extraction {
        var extraction = Extraction()
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return extraction }

        for item in root["builtin"] as? [[String: Any]] ?? [] {
            guard let signal = item["signal"] as? String,
                  let type = TrainingStore.canonicalType(for: signal),
                  let evidence = item["evidence"] as? String,
                  !evidence.trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }
            extraction.builtin.append(SignalExample(
                signalId: type.rawValue,
                evidence: String(evidence.prefix(280)),
                nudge: String((item["nudge"] as? String ?? "").prefix(80))))
        }

        for item in (root["custom"] as? [[String: Any]] ?? []).prefix(3) {
            guard let rawId = item["id"] as? String,
                  let description = item["description"] as? String,
                  !description.trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }
            let id = snakeCase(rawId)
            guard !id.isEmpty,
                  // A "custom" that aliases a built-in is a built-in.
                  TrainingStore.canonicalType(for: id) == nil,
                  !extraction.custom.contains(where: { $0.id == id })
            else { continue }
            extraction.custom.append(CustomProposal(
                id: String(id.prefix(40)),
                description: String(description.prefix(240)),
                nudge: String((item["nudge"] as? String ?? "").prefix(80)),
                evidence: String((item["evidence"] as? String ?? "").prefix(280))))
        }
        return extraction
    }

    static func snakeCase(_ s: String) -> String {
        let mapped = s.lowercased().map { c -> Character in
            (c.isLetter || c.isNumber) ? c : " "
        }
        return String(mapped).split(separator: " ").joined(separator: "_")
    }

    /// One round trip to the local model. Throws on engine failure; the
    /// caller treats that as "no extraction", never as an error the user
    /// has to deal with. Generous timeout: a cold 9B model needs prompt
    /// processing plus ~500 tokens of JSON, and nothing blocks on this.
    static func distill(note: String, model: String) async throws -> Extraction {
        let (system, user) = prompt(note: note)
        let reply = try await OllamaClient(model: model, timeout: 240)
            .complete(system: system, user: user)
        return parse(reply)
    }
}
