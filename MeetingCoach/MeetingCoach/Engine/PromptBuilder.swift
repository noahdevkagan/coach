import Foundation

/// Builds the system and user prompts for the LLM.
enum PromptBuilder {

    /// Keyword hints by signal ID — helps the 7B model match patterns reliably.
    private static let signalHints: [String: String] = [
        "repetition_loop": "DETECT: The same question or request rephrased 2+ times. Same intent, different words. They already answered. Examples: asking 'how do we standardize' then 'how do we replicate' then 'how do we scale' — all the same ask.",
        "escalation_rising": "DETECT: Short/clipped replies, 'I disagree', 'that's actually what we do', 'you already have an end goal', 'fair', 'sure' as resignation, reply length shrinking, defensive tone.",
        "resolution_capture": "DETECT: A clear deliverable stated — 'update this doc', 'I'll send that by Friday', 'let's do X'. Someone named what to do. Lock it before it drifts.",
        "unaddressed_objection": "DETECT: Someone says 'it depends', 'it's not that simple', 'that's an art', 'the product varies' — a real counterpoint — and the speaker pushes past it without acknowledging.",
        "stacked_asks": "DETECT: One person lists 3+ questions or requests in a single turn without numbering them. 'Also... and another thing... plus we need...'",
        "global_negative": "DETECT: 'We don't do that', 'we never', 'nobody does', 'I don't think we do' — sweeping negatives that trigger defensiveness.",
        "talk_time_imbalance": "DETECT: One person has spoken significantly more than others in the window. Count rough word share — if one person is 65%+ of the words, flag it.",
        "promise_vs_clock": "DETECT: Someone said 'keep this short', 'quick', 'tight', 'just two questions', 'five minutes' earlier, but the conversation has continued on the same topic for much longer.",
        "positive_reinforcement": "DETECT: A clean, specific ask with a clear deliverable. An action item with owner and date. A good meeting close. Someone naming exactly what they need. Reinforce good behavior.",
    ]

    static func buildSystem(rubric: Rubric, trainingExamples: [TrainingExample] = []) -> String {
        var lines = [
            "You are a real-time meeting coach for a founder/CEO. Analyze the transcript and flag coaching moments.",
            "",
            "YOUR JOB: Catch patterns the speaker can't see in the moment. Be aggressive — flag anything that matches. It is much better to over-flag than to miss a coaching moment. The speaker wants to be coached hard.",
            "",
            "CONTEXT: The speaker tends to use Socratic questioning when they already know the answer. Their fastest unlock is stating the end state in sentence one. Watch for repetition loops, rising tension, and unaddressed objections.",
            "",
            "Signals to check:",
        ]
        for s in rubric.signals {
            let hint = signalHints[s.id] ?? ""
            lines.append("  \(s.id): \(s.description.trimmingCharacters(in: .whitespacesAndNewlines))")
            if !hint.isEmpty {
                lines.append("    \(hint)")
            }
        }

        // Inject training examples as few-shot calibration
        let examples = trainingExamples.isEmpty ? TrainingStore.load() : trainingExamples
        if !examples.isEmpty {
            lines += ["", "CALIBRATION — real examples from past meetings the coach flagged correctly:"]
            // Use the most recent examples (up to 3 to stay within context)
            for example in examples.suffix(3) {
                let signals = example.signals
                if signals.isEmpty { continue }
                lines.append("")
                lines.append("  Example transcript excerpt:")
                // Include first few lines of transcript
                let excerptLines = example.transcriptExcerpt.components(separatedBy: CharacterSet.newlines).prefix(6)
                for l in excerptLines {
                    lines.append("    \(l)")
                }
                lines.append("  Correct signals:")
                for sig in signals {
                    var parts = "    - \(sig.signalId)"
                    if !sig.evidence.isEmpty { parts += " | evidence: \"\(sig.evidence.prefix(100))\"" }
                    if !sig.nudge.isEmpty { parts += " | nudge: \"\(sig.nudge.prefix(60))\"" }
                    lines.append(parts)
                }
            }
            lines.append("")
            lines.append("Use the above examples to calibrate your detection sensitivity. These are the kinds of patterns to catch.")
        }

        lines += [
            "",
            "RULES:",
            "- Check EVERY signal against the transcript. Return ALL that match.",
            "- Confidence 0.5+ means 'probably happening'. 0.7+ means 'clearly happening'. Use the full range.",
            "- Include positive_reinforcement when something good happens. The coach should praise too, not just scold.",
            "- Evidence must be an exact quote from the transcript.",
            "",
            "Return a JSON array:",
            #"[{"signal_id":"<id>","confidence":<0.0-1.0>,"evidence":"<exact quote>","nudge":"<actionable tip, 12 words max>"}]"#,
            "",
            "Return [] ONLY if the window is pure small talk with zero coaching moments.",
        ]
        return lines.joined(separator: "\n")
    }

    static func buildUser(window: [Utterance], summary: String, now: TimeInterval) -> String {
        let ts = formatTime(now)
        // Join consecutive utterances from the same speaker into flowing text
        let joined = joinUtterances(window)
        let win = joined.isEmpty ? "(empty)" :
            joined.map { "[\($0.formattedTime)] \($0.speaker): \($0.text)" }
                  .joined(separator: "\n")
        return "Summary: \(summary)\n\nWindow (clock=\(ts)):\n\(win)\n\nJSON:"
    }

    /// Build an end-of-meeting summary prompt from all coaching calls and transcript.
    static func buildSummaryPrompt(calls: [CoachingCall], transcript: String, durationMinutes: Int) -> (system: String, user: String) {
        let system = """
        You are a meeting coach. The meeting just ended. Write a concise post-meeting debrief.

        Include:
        1. A 2-3 sentence summary of what was discussed
        2. Key coaching moments that were flagged (grouped by theme)
        3. A "Decision Ledger" — a table of decisions, owners, and dates mentioned (flag where they're missing)
        4. Top 3 things to do differently next meeting

        Keep it under 400 words. Be direct and actionable.
        """

        var userLines = [
            "Meeting duration: \(durationMinutes) minutes",
        ]

        if !calls.isEmpty {
            userLines.append("\n\(calls.count) coaching signals fired:")
            for call in calls {
                userLines.append("[\(call.formattedTime)] \(call.signalId) (\(Int(call.confidence * 100))%): \(call.nudge) — \(call.evidence)")
            }
        } else {
            userLines.append("\nNo coaching signals fired during this meeting.")
        }

        if !transcript.isEmpty {
            let trimmed = String(transcript.prefix(2000))
            userLines.append("\nTranscript excerpt:\n\(trimmed)")
        }

        userLines.append("\nProvide the debrief now.")
        return (system, userLines.joined(separator: "\n"))
    }

    // MARK: - Helpers

    /// Join consecutive same-speaker utterances into one line so the LLM sees
    /// coherent sentences instead of fragmented chunks.
    private static func joinUtterances(_ utterances: [Utterance]) -> [Utterance] {
        guard !utterances.isEmpty else { return [] }
        var result: [Utterance] = []
        var currentSpeaker = utterances[0].speaker
        var currentTime = utterances[0].t
        var currentText = utterances[0].text

        for u in utterances.dropFirst() {
            if u.speaker == currentSpeaker {
                currentText += " " + u.text
            } else {
                result.append(Utterance(t: currentTime, speaker: currentSpeaker, text: currentText))
                currentSpeaker = u.speaker
                currentTime = u.t
                currentText = u.text
            }
        }
        result.append(Utterance(t: currentTime, speaker: currentSpeaker, text: currentText))
        return result
    }

    private static func formatTime(_ t: TimeInterval) -> String {
        let mm = Int(t) / 60
        let ss = Int(t) % 60
        return String(format: "%02d:%02d", mm, ss)
    }
}
