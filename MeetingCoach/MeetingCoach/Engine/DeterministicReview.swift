import Foundation

/// Post-call review computed purely from session data — no LLM required.
/// Used when no local model is installed (or the engine fails), so the
/// review moment works on a fresh zero-download install. Emits the same
/// MeetingReview struct as the LLM path, so the WiFi-off review renders in
/// the identical structured layout.
enum DeterministicReview {

    static func review(nudges: [Nudge],
                       utterances: [Utterance],
                       context: PreCallContext,
                       durationMinutes: Int,
                       talkShare: Double?) -> MeetingReview {
        var review = MeetingReview(talkShare: talkShare, isDeterministic: true)

        // Summary. Talk share comes from the caller's TalkStats — the same
        // number the meter, session header, and recap show; a second
        // formula here would let one session display two different ratios.
        var summary = "\(durationMinutes) min \(context.effectiveMeetingType.displayName.lowercased()) meeting."
        if let share = talkShare {
            summary += " You spoke \(Int(share * 100))% of the time."
        }
        summary += " Install a local AI model (Advanced → Model) and this review becomes real meeting notes — decisions, owners, deadlines."

        let corrective = countsByType(nudges.filter { !$0.type.isPositive })
        let wins = countsByType(nudges.filter { $0.type.isPositive })
        if corrective.isEmpty && wins.isEmpty {
            summary += " No coaching patterns fired — clean session."
        }
        review.summary = summary

        // Corrective patterns as takeaways, most frequent first — display
        // names only, never signal ids.
        for (type, count) in corrective.prefix(5) {
            review.takeaways.append("\(type.displayName) fired \(count == 1 ? "once" : "\(count)×") — \(advice(for: type))")
        }
        for (type, count) in wins.prefix(3) {
            review.wins.append(count > 1 ? "\(type.displayName) ×\(count)" : type.displayName)
        }

        // Commitments heard (keyword scan — approximate on purpose) become
        // the checkable next steps, so the list is never empty offline.
        review.actionItems = commitmentItems(utterances)

        if let (topType, count) = corrective.first {
            review.nextFocus = "Watch \(topType.displayName.lowercased()) — it fired \(count)×. \(advice(for: topType))"
        }
        return review
    }

    private static func countsByType(_ nudges: [Nudge]) -> [(NudgeType, Int)] {
        var counts: [NudgeType: Int] = [:]
        for n in nudges { counts[n.type, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    private static let commitmentPattern = try! NSRegularExpression(
        pattern: #"\b(i'?ll|i will|we'?ll|we will|let me|i can send|i owe you)\b|\bby (monday|tuesday|wednesday|thursday|friday|tomorrow|next week|end of|eod|eow)\b"#,
        options: [.caseInsensitive])

    private static func commitmentItems(_ utterances: [Utterance]) -> [ActionItem] {
        var result: [ActionItem] = []
        for u in utterances {
            // Transcripts carry smart apostrophes ("I’ll") — fold before
            // matching, but quote the original text.
            let matchable = TextAnalysis.normalize(u.text)
            let range = NSRange(matchable.startIndex..., in: matchable)
            guard commitmentPattern.firstMatch(in: matchable, range: range) != nil else { continue }
            // Whole thoughts only: 3-word fragments like "done by Friday."
            // quoted out of context read as noise, not action items (Noah,
            // 2026-08-04). Better four real moments than five shreds.
            guard u.text.split(separator: " ").count >= 8 else { continue }
            let quote = u.text.count > 120 ? String(u.text.prefix(117)) + "..." : u.text
            result.append(ActionItem(text: "“\(quote)” — \(u.speaker), \(u.formattedTime)"))
            if result.count == 4 { break }
        }
        return result
    }

    private static func advice(for type: NudgeType) -> String {
        switch type {
        case .talkTime, .voiceShare:
            return "Try ending your point one sentence earlier and handing the floor back with a question."
        case .interruption:
            return "Let their sentence land before you start yours."
        case .stackedQuestions:
            return "Ask one question, then stop talking."
        case .unansweredQuestion, .questionParked:
            return "When they ask something, answer it before moving on."
        case .missingDiscovery:
            return "Open with a question you don't know the answer to."
        case .repetitionLoop:
            return "If you've said it twice, either decide it or park it."
        case .commitmentGap, .hedgeNotPinned:
            return "Turn soft commitments into an owner and a date before the call ends."
        case .noDecision, .droppedThread:
            return "Close each open thread out loud: decision, owner, date."
        case .overrun, .timeCheck:
            return "Call the remaining time out loud at the two-thirds mark."
        case .vagueAnswer:
            return "Follow vague answers with 'what specifically?'"
        case .goingQuiet, .yesMan:
            return "Draw quiet voices out by name before deciding."
        case .buriedSignal:
            return "When something important gets said, stop and dig in."
        default:
            return "Pick one moment it fired and decide what you'd do differently."
        }
    }
}
