import Foundation

/// Port of transcript.py:simulate — walks a clock through the meeting and yields
/// triggers on heartbeats, long pauses, and speaker handoffs.
func simulate(utterances: [Utterance], rubric: Rubric) -> AsyncStream<Trigger> {
    AsyncStream { continuation in
        guard !utterances.isEmpty else {
            continuation.finish()
            return
        }

        let cad = rubric.cadence
        let winSecs = Double(rubric.window.transcriptSeconds)
        let start = utterances.first!.t
        let end = utterances.last!.t

        // 1) Heartbeat grid
        var events: [(TriggerReason, TimeInterval)] = []
        var t = start + Double(cad.heartbeatSeconds)
        while t <= end + Double(cad.heartbeatSeconds) {
            events.append((.heartbeat, min(t, end)))
            t += Double(cad.heartbeatSeconds)
        }

        // 2) Long pauses + speaker handoffs
        for (prev, cur) in zip(utterances, utterances.dropFirst()) {
            let gap = cur.t - prev.t
            if gap >= Double(cad.extraCheckOnLongPauseSeconds) {
                events.append((.longPause, cur.t))
            }
            if cad.extraCheckOnSpeakerHandoff && cur.speaker != prev.speaker {
                events.append((.speakerHandoff, cur.t))
            }
        }

        events.sort { $0.1 < $1.1 }

        var firedTimes = Set<TimeInterval>()
        for (reason, now) in events {
            guard !firedTimes.contains(now) else { continue }
            firedTimes.insert(now)
            let fullWindow = utterances.filter { now - winSecs <= $0.t && $0.t <= now }
            let window = Array(fullWindow.suffix(20)) // cap at 20 utterances to keep prompt small
            guard !window.isEmpty else { continue }
            let older = rubric.window.keepRunningSummary
                ? utterances.filter { $0.t < now - winSecs }
                : []
            let summary = runningSummary(older)
            continuation.yield(Trigger(reason: reason, now: now, window: window, summary: summary))
        }
        continuation.finish()
    }
}

/// Port of transcript.py:_running_summary — cheap extractive summary.
private func runningSummary(_ older: [Utterance], maxLines: Int = 4) -> String {
    if older.isEmpty { return "(meeting just started)" }
    let tail = older.suffix(maxLines)
    return tail.map { u in
        "- [\(u.formattedTime)] \(u.speaker): \(u.text)"
    }.joined(separator: "\n")
}
