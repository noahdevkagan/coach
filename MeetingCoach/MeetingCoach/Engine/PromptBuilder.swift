import Foundation

/// Builds LLM prompts for the post-call review.
enum PromptBuilder {

    /// Build a post-call review prompt that includes nudges, feedback, pre-call context, and transcript.
    static func buildPostCallReviewPrompt(nudges: [Nudge], transcript: String,
                                          context: PreCallContext,
                                          durationMinutes: Int,
                                          languageName: String? = nil)
        -> (system: String, user: String) {
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
        let languageInstruction: String
        if let languageName {
            languageInstruction = "Write all section content in \(languageName). The five literal header lines TITLE:, SUMMARY:, NOTES:, NEXT STEPS:, and NEXT MEETING FOCUS: must stay exactly in English; they are the only language exception."
        } else {
            languageInstruction = "Write section content in the transcript's dominant language. The five literal header lines TITLE:, SUMMARY:, NOTES:, NEXT STEPS:, and NEXT MEETING FOCUS: must stay exactly in English."
        }

        let system = """
        You write crisp post-meeting notes — the notes the user will send to the other participants. Someone who missed the meeting must learn from them exactly what matters, what was decided, and who owes what by when. You are NOT a communication coach: no advice about speaking style, structure, pausing, or delivery anywhere except the final one-sentence NEXT MEETING FOCUS.

        \(languageInstruction)

        Your ENTIRE reply must be exactly these five labeled sections, nothing before or after. Begin your reply with the literal line "TITLE:".

        TITLE:
        The meeting named like a good file name, max 6 words. Format: "<other person's first name> · <the one dominant topic>" when the transcript makes clear who the meeting was with, else just the topic. Name the SUBJECT DISCUSSED, never the activity ("sync", "call", "meeting", "discussion" are banned words).

        SUMMARY:
        A TL;DR leading with the headline — the single most important thing decided, learned, or at stake. Then at most two more sentences on where things landed. Never mention meeting length, utterance counts, or talk percentages.

        NOTES:
        The body of the meeting, grouped by topic. 2-5 topic sections. Each section is one line starting with "### " naming the topic in 2-5 words (a noun phrase like "Pricing and margin", never "Discussion" or "Updates"), then 3-8 lines each starting with "- ". Be thorough: a reader who missed the meeting should get every decision, number, and named person from these bullets — more short factual bullets beat fewer vague ones. Every bullet is a dense fact, not a vague gesture:
        - Keep the specifics EXACTLY as said: numbers, dollar amounts, percentages, dates, names of people/products/companies. "~$6-7k/month, lowest Meta profit" beats "high cost, low return".
        - Record decisions with their reasoning, and open questions as open.
        - When people disagreed, say who pushed back on what and how it resolved (or that it didn't).
        - Attribute positions when it matters ("X prefers…", "Y's concern:").
        Skip small talk entirely. Order sections by importance, not chronology.

        NEXT STEPS:
        1-6 lines, each starting with "- ", formatted "Action (owner) — one line of detail: the how or the success bar". Every line carries its parenthesized owner right after the action; write "(owner unclear)" when the transcript never said. Only commitments actually stated or clearly implied. Include a deadline ONLY when one was actually spoken — NEVER invent one: if the transcript has no date, the line has no date. Phrases like "by end of week", "within 48 hours", "by next sprint" are banned unless those exact commitments were said. Mark anything called urgent with "[critical]".

        NEXT MEETING FOCUS:
        One sentence on the most valuable thing to do differently next time — the ONLY place coaching signals may appear.

        Example of the exact shape (invented content — never copy its content or language):
        TITLE:
        Caitlin · launch margins
        SUMMARY:
        Launches are pacing, but the headline is margin — targets are being hit at roughly zero profit, so margin is now the #1 priority.
        NOTES:
        ### Margin over volume
        - August hit the launch target for the first time this year, but at roughly zero profit; margin is now priority #1.
        - Lead tier is the strongest predictor of performance; Tier 1 beats Tier 2 by ~2.4-3x, so Launchpad becomes the default.
        - Caitlin pushed back on cutting spend mid-quarter — agreed to hold spend and gate launches on a margin floor instead.
        ### Retro QA of live tools
        - Status: 7 pass / 6 fail; passing tools are cleared to ship, failing ones stay dark until fixed.
        - Kim's concern: QA has no owner once Abe rotates off in October — unresolved.
        NEXT STEPS:
        - Build the rev-share margin model and operating-principles one-pager (Caitlin) — it states the margin floor every launch must clear [critical]
        - Finish retro QA on the live Radar tools (Kim and Abe) — clear the 6 failing tools or mark them end-of-life
        NEXT MEETING FOCUS:
        Watch talk time — hand the floor back with a question one sentence earlier.

        Never invent facts that are not in the transcript. People: use only
        names the transcript itself establishes for a speaker. Someone who
        is merely mentioned ("I met with Chad") is NOT a speaker — when a
        speaker is never named, call them by their transcript label ("Them")
        rather than guessing. A NEXT STEPS owner must be a name from the
        transcript, "You", "Them", or "(owner unclear)". Final check before
        replying: delete any deadline or timeframe in NEXT STEPS that is
        not verbatim from the transcript. Keep the whole
        reply under 700 words. Plain text except for the structure shown:
        the five header lines, "### " topic lines, and "- " bullets — no
        bold, backticks, emoji, tables, or numbered lists. Refer to
        coaching signals by plain names (say "talk time", never camelCase
        ids).
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
            // Sized against the review call's 12288 num_ctx: 32K chars is
            // ~8K tokens, leaving room for this system prompt and a 1500-
            // token reply. Noah's real 43-min meeting was 35K chars and the
            // old 24K cap amputated exactly the middle where the team
            // review happened (2026-09-04) — most meetings now fit whole.
            if t.count > 32_000 {
                t = t.prefix(10_000) + "\n[… middle of the meeting trimmed …]\n" + t.suffix(22_000)
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

        userLines.append("\nWrite the five sections now, starting with TITLE:.")
        return (system, userLines.joined(separator: "\n"))
    }
}
