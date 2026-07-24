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
        You are a meeting coach. The meeting just ended. Write a concise post-meeting review.

        Respond using EXACTLY these labeled sections, in this order:

        SUMMARY:
        2-3 plain sentences on what was discussed and how it went.

        KEY TAKEAWAYS:
        - one insight per line, each starting with "- " (include patterns you notice in the transcript, and what the coaching nudges and the user's feedback on them tell you)

        NEXT STEPS:
        - one concrete action per line, each starting with "- " (decisions, commitments, owners and dates mentioned — flag missing owners/dates)

        NEXT MEETING FOCUS:
        One sentence: the single most valuable thing to do differently next time.

        Rules: no markdown headers, no bold, no backticks, no tables. Refer to
        coaching signals by plain names (say "talk time", never camelCase ids).
        Keep the whole review under 300 words. Be direct and actionable.
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

        // Nudges
        if !nudges.isEmpty {
            userLines.append("\n\(nudges.count) nudges fired during the meeting:")
            for nudge in nudges {
                let feedbackStr = nudge.feedback.map { " [user feedback: \($0.rawValue)]" } ?? ""
                userLines.append("[\(nudge.formattedTime)] \(nudge.type.rawValue) (\(nudge.urgency.rawValue)): \(nudge.text)\(feedbackStr)")
            }
        } else {
            userLines.append("\nNo nudges fired during this meeting.")
        }

        // Transcript
        if !transcript.isEmpty {
            let trimmed = String(transcript.prefix(3000))
            userLines.append("\nTranscript:\n\(trimmed)")
        }

        userLines.append("\nProvide the review now.")
        return (system, userLines.joined(separator: "\n"))
    }
}
