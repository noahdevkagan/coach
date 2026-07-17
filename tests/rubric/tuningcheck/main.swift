import Foundation

// Rubric tuning plumbing checks against the REAL SignalEngine + monitors.
//
// 1. A signal disabled by the rubric never fires, even on a scenario that
//    reliably triggers it.
// 2. Neutral tuning entries are behavior-identical to no tuning at all —
//    the regression tripwire that keeps the golden replay meaningful.
// 3. A threshold multiplier shifts fire timing in the right direction
//    (checked at the signal level so machine-local adaptive state can't
//    skew the assert).

let ctx = PreCallContext(meetingGoal: "", scheduledDurationMinutes: 30)

/// A monologue: You talking continuously in Parakeet-shaped commits.
func monologue(until end: Double) -> [(arrival: Double, u: Utterance)] {
    var result: [(Double, Utterance)] = [
        (6.0, Utterance(t: 5, speaker: "Them", text: "Where do we stand?", endT: 5.5)),
    ]
    var t = 10.0
    while t < end {
        let chunkEnd = min(t + 10, end)
        result.append((chunkEnd + 1, Utterance(
            t: t, speaker: "You",
            text: "and the way I think about it is that the pricing has to reflect the audience split we bring",
            endT: chunkEnd)))
        t = chunkEnd
    }
    return result
}

/// Replay the scenario through an engine, 5s ticks; returns fired types in order.
func replay(tuning: RubricTuning, until end: Double = 120) -> [NudgeType] {
    var engine = SignalEngine(context: ctx, tuning: tuning)
    var pending = monologue(until: end)
    var inserted: [Utterance] = []
    var fired: [NudgeType] = []
    var clock = 0.0
    while clock <= end + 10 {
        clock += 5
        while let next = pending.first, next.0 <= clock {
            inserted.append(next.1); pending.removeFirst()
        }
        guard !inserted.isEmpty else { continue }
        fired.append(contentsOf: engine.evaluate(utterances: inserted, elapsed: clock, context: ctx).map(\.type))
    }
    return fired
}

var fail = false

// 1. Disabled talkTime never fires; stock tuning must fire it. The 120s
//    monologue clears even a 2.0x-adapted threshold (30s * 2 = 60s).
var disable = RubricTuning()
disable["talkTime"] = SignalTuning(enabled: false, thresholdMultiplier: 1.0, cooldownMultiplier: 1.0)
let withDisabled = replay(tuning: disable)
let stock = replay(tuning: [:])
if !withDisabled.contains(.talkTime) && stock.contains(.talkTime) {
    print("disabled signal: stock fires talkTime, disabled never does -> PASS")
} else {
    print("disabled signal: stock=\(stock.contains(.talkTime)) disabled=\(withDisabled.contains(.talkTime)) (want true/false) -> FAIL")
    fail = true
}

// 2. Neutral explicit tuning == no tuning (identical fire sequence).
var neutral = RubricTuning()
for key in ["talkTime", "voiceShare", "interruption", "stackedQuestions", "missingDiscovery"] {
    neutral[key] = SignalTuning(enabled: true, thresholdMultiplier: 1.0, cooldownMultiplier: 1.0)
}
let neutralFired = replay(tuning: neutral)
if neutralFired == stock {
    print("neutral tuning: identical fire sequence to stock (\(stock.count) nudges) -> PASS")
} else {
    print("neutral tuning: \(neutralFired) != stock \(stock) -> FAIL")
    fail = true
}

// 3. Threshold multiplier shifts timing (signal-level, deterministic).
func talkTimeFireTick(multiplier: Double) -> Double? {
    var signal = TalkTimeSignal()
    signal.threshold *= multiplier
    var builder = TurnBuilder()
    var pending = monologue(until: 120)
    var inserted: [Utterance] = []
    var clock = 0.0
    while clock <= 130 {
        clock += 5
        while let next = pending.first, next.0 <= clock {
            inserted.append(next.1); pending.removeFirst()
        }
        builder.rebuild(inserted)
        let input = SignalInput(utterances: inserted, turns: builder.turns,
                                fresh: inserted[...], elapsed: clock, context: ctx,
                                speakerLabelsReliable: true)
        if signal.evaluate(input) != nil { return clock }
    }
    return nil
}
let base = talkTimeFireTick(multiplier: 1.0)
let relaxed = talkTimeFireTick(multiplier: 1.5)
if let base, let relaxed, relaxed > base {
    print("threshold multiplier: 1.0x fires at \(Int(base))s, 1.5x at \(Int(relaxed))s -> PASS")
} else {
    print("threshold multiplier: base=\(base.map(Int.init).map(String.init) ?? "never") relaxed=\(relaxed.map(Int.init).map(String.init) ?? "never") (want later) -> FAIL")
    fail = true
}

exit(fail ? 1 : 0)
