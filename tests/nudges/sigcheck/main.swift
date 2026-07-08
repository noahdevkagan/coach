import Foundation

// TalkTime live-timing check with Parakeet-shaped utterances.
//
// The backtest fixtures can't model this: their format has no endT, so a
// 30s spoken chunk looks like a point event and the turn breaks. Live,
// Parakeet commits carry real [t, endT] spans; this check proves the
// signal still fires promptly with chunky commits.
//
// Scenario: speech starts t=30; the 30s window-cap commit arrives at wall
// 61 spanning [30,60]; a second commit at 77 spanning [60,76]. Ticking
// every 5s like the app, TalkTime (threshold 30s) must fire by tick 70.
var builder = TurnBuilder()
var signal = TalkTimeSignal()
var utts: [(arrival: Double, u: Utterance)] = [
    (6.0,  Utterance(t: 5,  speaker: "Them", text: "So where do we stand on the partnership?", endT: 5.5)),
    (61.0, Utterance(t: 30, speaker: "You",  text: "So the way I think about the partnership is that we bring the audience and they bring the product, and the pricing needs to reflect that split", endT: 60)),
    (77.0, Utterance(t: 60, speaker: "You",  text: "because our list did the heavy lifting on every launch.", endT: 76)),
]
var inserted: [Utterance] = []
var firedAt: Double?
var clock = 0.0
while clock <= 120 {
    clock += 5
    while let next = utts.first, next.arrival <= clock {
        inserted.append(next.u); utts.removeFirst()
    }
    builder.rebuild(inserted)
    let input = SignalInput(utterances: inserted, turns: builder.turns,
                            fresh: inserted[...], elapsed: clock,
                            context: PreCallContext(meetingGoal: "", scheduledDurationMinutes: 30),
                            speakerLabelsReliable: true)
    if signal.evaluate(input) != nil, firedAt == nil {
        firedAt = clock
    }
}

var fail = false
if let firedAt, firedAt <= 70 {
    print("talkTime timing: fired at tick \(Int(firedAt))s for speech starting t=30 (threshold 30s) -> PASS")
} else {
    print("talkTime timing: \(firedAt.map { "fired late at \(Int($0))s" } ?? "never fired") -> FAIL")
    print("  Parakeet-shaped commits must keep the monologue turn alive (TurnBuilder joins on real endT).")
    fail = true
}

// Diarizer relabel must not duplicate turns: invalidateTurnCache() +
// re-evaluate rebuilds the same history, so the turn count must not grow.
var engine = SignalEngine(context: PreCallContext(meetingGoal: "", scheduledDurationMinutes: 30))
var history = [
    Utterance(t: 5,  speaker: "Meeting", text: "How are we looking on the launch?", endT: 7),
    Utterance(t: 20, speaker: "Meeting", text: "Honestly we are two weeks behind.", endT: 23),
    Utterance(t: 40, speaker: "Meeting", text: "Okay, what would unblock the team?", endT: 43),
]
_ = engine.evaluate(utterances: history, elapsed: 45, context: PreCallContext(meetingGoal: "", scheduledDurationMinutes: 30))
let before = engine.turns.count
history[0].speaker = "Speaker 1"   // what applyDiarization does
engine.invalidateTurnCache()
_ = engine.evaluate(utterances: history, elapsed: 50, context: PreCallContext(meetingGoal: "", scheduledDurationMinutes: 30))
let after = engine.turns.count
if after <= before + 1 {           // relabel may split a merged turn, never duplicate
    print("relabel rebuild: \(before) turns -> \(after) after invalidate+relabel -> PASS")
} else {
    print("relabel rebuild: \(before) turns -> \(after) after invalidate+relabel -> FAIL (duplicated turns)")
    fail = true
}
exit(fail ? 1 : 0)
