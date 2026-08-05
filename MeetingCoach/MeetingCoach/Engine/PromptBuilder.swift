import Foundation

/// Builds LLM prompts for the post-call review.
enum PromptBuilder {

    /// Build a post-call review prompt that includes nudges, feedback, pre-call context, and transcript.
    static func buildPostCallReviewPrompt(nudges: [Nudge], transcript: String, context: PreCallContext, durationMinutes: Int) -> (system: String, user: String) {
        // Strictly-delimited sections, one item per line — the app parses
        // this into a structured card (MeetingReview.parse). Small local
        // models are unreliable at JSON; labeled sections survive better,
        // and the parser degrades to plain text when even these are ignored.
        // Tuned against gemma4:e4b on a real 73-min transcript
        // (2026-08-04): the coach framing pulled small models into
        // delivery-advice lectures, so the coach role is explicitly
        // banned; the inline example is what actually makes a 4B model
        // hold the section shape. MeetingReview.parse still tolerates the
        // decoration and renamed headers they sprinkle in anyway.
        let system = """
        You write crisp post-meeting notes — the notes the user will send to the other participants. Someone who missed the meeting must learn from them exactly what matters, what was decided, and who owes what by when. You are NOT a communication coach: no advice about speaking style, structure, pausing, or delivery anywhere except the final one-sentence NEXT MEETING FOCUS.

        Your ENTIRE reply must be exactly these four labeled sections, nothing before or after. Begin your reply with the literal line "SUMMARY:".

        SUMMARY:
        A TL;DR leading with the headline — the single most important thing decided, learned, or at stake. Then at most two more sentences on where things landed. Never mention meeting length, utterance counts, or talk percentages.

        KEY TAKEAWAYS:
        3-6 lines, each starting with "- ": decisions, positions, and status updates WITH their specifics (numbers, dates, names actually said).

        NEXT STEPS:
        1-6 lines, each starting with "- ", formatted "Owner — action — deadline". Only commitments actually stated or clearly implied. Write "(owner unclear)" or "(no deadline set)" when the transcript never said. Mark anything called urgent with "[critical]".

        NEXT MEETING FOCUS:
        One sentence on the most valuable thing to do differently next time — the ONLY place coaching signals may appear.

        Example of the exact shape (invented content — never copy it):
        SUMMARY:
        Launches are pacing, but the headline is margin — targets are being hit at roughly zero profit, so margin is now the #1 priority.
        KEY TAKEAWAYS:
        - Lead tier is the strongest predictor of performance; Tier 1 beats Tier 2 by ~2.4-3x, so Launchpad becomes the default.
        - Retro QA of live tools stands at 7 pass / 6 fail; passing tools are cleared to ship.
        NEXT STEPS:
        - Caitlin — rev-share margin model + operating-principles one-pager — by Friday [critical]
        - Kim and Abe — finish retro QA on live Radar tools — (no deadline set)
        NEXT MEETING FOCUS:
        Watch talk time — hand the floor back with a question one sentence earlier.

        Never invent facts that are not in the transcript. Keep the whole
        reply under 350 words. Plain text only: no markdown headers, bold,
        backticks, emoji, or numbered lists. Refer to coaching signals by
        plain names (say "talk time", never camelCase ids).
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
            // Catalog models all take 32K+ context; a 73-minute meeting is
            // ~10-14K chars of turns, so most meetings now fit whole. The
            // old 8K cap amputated exactly the middle where decisions live.
            if t.count > 24_000 {
                t = t.prefix(8_000) + "\n[… middle of the meeting trimmed …]\n" + t.suffix(16_000)
            }
            userLines.append("\nTranscript (You = the user, the person these notes are for):\n\(t)")
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

        userLines.append("\nWrite the four sections now, starting with SUMMARY:.")
        return (system, userLines.joined(separator: "\n"))
    }
}
