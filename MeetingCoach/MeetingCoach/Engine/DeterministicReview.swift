import Foundation

/// Post-call review computed purely from session data — no LLM required.
/// Rendered when no local model is installed (or the engine fails), so the
/// review moment works on a fresh zero-download install. Mirrors the shape
/// of the LLM review: summary line, what fired, wins, commitments, next focus.
enum DeterministicReview {

    static func generate(nudges: [Nudge],
                         utterances: [Utterance],
                         context: PreCallContext,
                         durationMinutes: Int,
                         talkShare: Double?) -> String {
        var lines: [String] = []
        lines.append("**Instant review** — generated on-device from this session's signals (add a local model in Settings for a deeper AI review).")
        lines.append("")

        // Summary line. Talk share comes from the caller's TalkStats — the
        // same number the meter, session header, and recap show; a second
        // formula here would let one session display two different ratios.
        var summary = "\(durationMinutes) min \(context.effectiveMeetingType.displayName.lowercased()) meeting · \(utterances.count) utterances"
        if let share = talkShare {
            summary += " · you spoke \(Int(share * 100))% of the time"
        }
        lines.append("**Summary:** \(summary).")
        lines.append("")

        // Corrective patterns, most frequent first
        let corrective = countsByType(nudges.filter { !$0.type.isPositive })
        if !corrective.isEmpty {
            lines.append("**What fired:**")
            for (type, count) in corrective {
                lines.append("- \(type.displayName) ×\(count)")
            }
            lines.append("")
        }

        // Positive reinforcement
        let wins = countsByType(nudges.filter { $0.type.isPositive })
        if !wins.isEmpty {
            let winList = wins.map { "\($0.0.displayName) ×\($0.1)" }.joined(separator: ", ")
            lines.append("**Wins:** \(winList)")
            lines.append("")
        }

        if corrective.isEmpty && wins.isEmpty {
            lines.append("No coaching patterns fired — clean session.")
            lines.append("")
        }

        // Commitments heard (keyword scan — approximate on purpose)
        let commitments = commitmentLines(utterances)
        if !commitments.isEmpty {
            lines.append("**Possible commitments heard:**")
            lines.append(contentsOf: commitments)
            lines.append("")
        }

        // Single next-meeting focus: the most frequent corrective pattern
        if let (topType, count) = corrective.first {
            lines.append("**Next meeting:** watch \(topType.displayName.lowercased()) — it fired \(count)×. \(advice(for: topType))")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func countsByType(_ nudges: [Nudge]) -> [(NudgeType, Int)] {
        var counts: [NudgeType: Int] = [:]
        for n in nudges { counts[n.type, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    private static let commitmentPattern = try! NSRegularExpression(
        pattern: #"\b(i'?ll|i will|we'?ll|we will|let me|i can send|i owe you)\b|\bby (monday|tuesday|wednesday|thursday|friday|tomorrow|next week|end of|eod|eow)\b"#,
        options: [.caseInsensitive])

    private static func commitmentLines(_ utterances: [Utterance]) -> [String] {
        var result: [String] = []
        for u in utterances {
            // Transcripts carry smart apostrophes ("I’ll") — fold before
            // matching, but quote the original text.
            let matchable = TextAnalysis.normalize(u.text)
            let range = NSRange(matchable.startIndex..., in: matchable)
            guard commitmentPattern.firstMatch(in: matchable, range: range) != nil else { continue }
            let quote = u.text.count > 120 ? String(u.text.prefix(117)) + "..." : u.text
            result.append("- \"\(quote)\" (\(u.formattedTime), \(u.speaker))")
            if result.count == 5 { break }
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
