import Foundation

/// Builds LLM prompts for the post-call review.
enum PromptBuilder {

    /// Build a post-call review prompt that includes nudges, feedback, pre-call context, and transcript.
    static func buildPostCallReviewPrompt(nudges: [Nudge], transcript: String, context: PreCallContext, durationMinutes: Int) -> (system: String, user: String) {
        // Strictly-delimited sections, one item per line — the app parses
        // this into a structured card (MeetingReview.parse). Small local
        // models are unreliable at JSON; labeled sections survive better,
        // and the parser degrades to plain text when even these are ignored.
        let system = """
        You are reviewing a meeting that just ended. Write a concise review of THIS conversation — what was actually discussed, decided, and promised. Ground every point in the transcript; reference specific topics and moments.

        Respond using EXACTLY these labeled sections, in this order:

        SUMMARY:
        2-3 plain sentences on what the conversation was about — the topics covered, positions taken, and where things landed. Content only; do not mention coaching signals here.

        KEY TAKEAWAYS:
        - one per line, each starting with "- ": the most important things said, learned, or decided (new information, concerns raised, agreements reached). About the conversation, not the user's speaking habits.

        NEXT STEPS:
        - one concrete action per line, each starting with "- ": commitments and follow-ups people actually stated, with owner and date when mentioned (flag missing owners/dates)

        NEXT MEETING FOCUS:
        One sentence: the single most valuable thing to do differently next time. This is the ONLY section that may draw on the coaching signals.

        Rules: no markdown headers, no bold, no backticks, no tables. Never
        invent facts that are not in the transcript. Refer to coaching signals
        by plain names (say "talk time", never camelCase ids). Keep the whole
        review under 300 words. Be direct and specific.
        """

        var userLines = [
            "Meeting duration: \(durationMinutes) minutes",
        ]

        // Pre-call context
        if !context.meetingGoal.isEmpty {
            userLines.append("\nMeeting goal: \(context.meetingGoal)")
        }
        if !context.participants.isEmpty {
            userLines.append("Participants: \(context.participants.map { "\($0.name) (\($0.role))" }.joined(separator: ", "))")
        }
        if !context.myKnownTendencies.isEmpty {
            userLines.append("Known tendencies: \(context.myKnownTendencies.joined(separator: ", "))")
        }

        // Transcript first and large — it is what the review should be
        // about. When it doesn't fit, keep the opening (topics get framed
        // early) and the tail (decisions and commitments land late) instead
        // of the first N chars only.
        if !transcript.isEmpty {
            var t = transcript
            if t.count > 8000 {
                t = t.prefix(2500) + "\n[… middle of the meeting trimmed …]\n" + t.suffix(5500)
            }
            userLines.append("\nTranscript (You = the person being coached):\n\(t)")
        }

        // Coaching signals as compact totals only. The full timestamped
        // nudge list used to dominate the prompt and reviews came back
        // about the coaching instead of the call; totals are enough for the
        // focus section. Nudges the user explicitly rated keep their text —
        // that feedback is signal about what landed.
        if !nudges.isEmpty {
            var counts: [String: Int] = [:]
            for nudge in nudges { counts[nudge.type.displayName, default: 0] += 1 }
            let totals = counts.sorted { $0.value > $1.value }
                .map { "\($0.key) ×\($0.value)" }
                .joined(separator: ", ")
            userLines.append("\nCoaching signals fired (use ONLY for NEXT MEETING FOCUS): \(totals)")
            for nudge in nudges.filter({ $0.feedback != nil }).prefix(6) {
                userLines.append("[\(nudge.formattedTime)] \(nudge.type.displayName): \(nudge.text) [user feedback: \(nudge.feedback!.rawValue)]")
            }
        } else {
            userLines.append("\nNo coaching signals fired during this meeting.")
        }

        userLines.append("\nProvide the review now.")
        return (system, userLines.joined(separator: "\n"))
    }
}
