import Foundation

/// Builds LLM prompts for the post-call review.
enum PromptBuilder {

    /// Build a post-call review prompt that includes nudges, feedback, pre-call context, and transcript.
    static func buildPostCallReviewPrompt(nudges: [Nudge], transcript: String, context: PreCallContext, durationMinutes: Int) -> (system: String, user: String) {
        let system = """
        You are a meeting coach. The meeting just ended. Write a concise post-meeting review.

        Include:
        1. A 2-3 sentence summary of what was discussed
        2. Nudge analysis — which nudges fired, which the user found useful/annoying/wrong, and what that tells you
        3. A "Decision Ledger" — a table of decisions, owners, and dates mentioned (flag where they're missing)
        4. Patterns missed — things you notice in the transcript that the deterministic signals didn't catch
        5. Top 3 recommendations for the next meeting

        Keep it under 500 words. Be direct and actionable.
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
