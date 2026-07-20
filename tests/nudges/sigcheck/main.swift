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

// Two-way gate (2026-07-20 William meeting regression): the same monologue
// with NO other speaker yet — waiting alone on the call — must never fire
// talkTime. "You're still talking" to an empty room was marked wrong.
var soloBuilder = TurnBuilder()
var soloSignal = TalkTimeSignal()
var soloUtts: [(arrival: Double, u: Utterance)] = [
    (61.0, Utterance(t: 30, speaker: "You", text: "So the way I think about the partnership is that we bring the audience and they bring the product, and the pricing needs to reflect that split", endT: 60)),
    (77.0, Utterance(t: 60, speaker: "You", text: "because our list did the heavy lifting on every launch.", endT: 76)),
]
var soloInserted: [Utterance] = []
var soloFired = false
clock = 0.0
while clock <= 120 {
    clock += 5
    while let next = soloUtts.first, next.arrival <= clock {
        soloInserted.append(next.u); soloUtts.removeFirst()
    }
    soloBuilder.rebuild(soloInserted)
    let input = SignalInput(utterances: soloInserted, turns: soloBuilder.turns,
                            fresh: soloInserted[...], elapsed: clock,
                            context: PreCallContext(meetingGoal: "", scheduledDurationMinutes: 30),
                            speakerLabelsReliable: true)
    if soloSignal.evaluate(input) != nil { soloFired = true }
}
if !soloFired {
    print("talkTime two-way gate: solo monologue (nobody else has spoken) never fires -> PASS")
} else {
    print("talkTime two-way gate: fired while waiting alone on the call -> FAIL")
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

// Positive reinforcement: a short open question from You that pulls a long
// answer from Them fires questionLanded; a long You turn ending in "?" (a
// monologue, not an open question) must NOT.
let longAnswer = Array(repeating: "the honest answer is the process broke when we started building while designing", count: 8).joined(separator: " ")
func landed(question: String) -> Bool {
    var qBuilder = TurnBuilder()
    var qSignal = QuestionLandedSignal()
    let utts = [
        Utterance(t: 10, speaker: "You", text: question, endT: 14),
        Utterance(t: 16, speaker: "Them", text: longAnswer, endT: 55),
    ]
    for u in utts { qBuilder.append(u) }
    let qInput = SignalInput(utterances: utts, turns: qBuilder.turns,
                             fresh: utts[...], elapsed: 60,
                             context: PreCallContext(meetingGoal: "", scheduledDurationMinutes: 30),
                             speakerLabelsReliable: true)
    return qSignal.evaluate(qInput) != nil
}
let openQ = landed(question: "What should I know that I don't?")
let monologueQ = landed(question: Array(repeating: "so the way I see the launch working is that we anchor on the number and", count: 4).joined(separator: " ") + " does that make sense?")
if openQ && !monologueQ {
    print("questionLanded: open question fires, 60-word monologue-question doesn't -> PASS")
} else {
    print("questionLanded: open=\(openQ) monologue=\(monologueQ) (want true/false) -> FAIL")
    fail = true
}

// Phrase reinforcement respects the per-meeting fire cap.
var phraseSignal = PositiveSignals.ownershipHanded()
var firedCount = 0
for round in 0..<4 {
    let t = Double(round) * 1_000 + 50
    let u = [Utterance(t: t, speaker: "You", text: "This one is your call to make.", endT: t + 2)]
    var b = TurnBuilder(); for x in u { b.append(x) }
    let inp = SignalInput(utterances: u, turns: b.turns, fresh: u[...], elapsed: t + 5,
                          context: PreCallContext(meetingGoal: "", scheduledDurationMinutes: 30),
                          speakerLabelsReliable: true)
    if phraseSignal.evaluate(inp) != nil { firedCount += 1 }
}
if firedCount == 2 {
    print("positive phrase cap: 4 triggers -> \(firedCount) fires (max 2) -> PASS")
} else {
    print("positive phrase cap: 4 triggers -> \(firedCount) fires (want 2) -> FAIL")
    fail = true
}

// Overlay fatigue backoff: consecutive ignores stretch the display gap,
// any interaction resets it, urgent/focus nudges always break through.
func backoffCheck(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("backoff \(label): \(ok ? "PASS" : "FAIL\(detail.isEmpty ? "" : " — \(detail)")")")
    if !ok { fail = true }
}

var bo = NudgeBackoff()
backoffCheck(bo.requiredGap == 0, "no throttle before any ignores")
for _ in 0..<3 { bo.nudgeIgnored() }
backoffCheck(bo.requiredGap == 0, "first 3 consecutive ignores are free", "got \(bo.requiredGap)")
bo.nudgeIgnored()
backoffCheck(bo.requiredGap == 60, "4th ignore -> 60s gap", "got \(bo.requiredGap)")
bo.nudgeIgnored()
backoffCheck(bo.requiredGap == 120, "5th ignore -> 120s gap", "got \(bo.requiredGap)")
bo.nudgeIgnored()
backoffCheck(bo.requiredGap == 240, "6th ignore -> 240s gap", "got \(bo.requiredGap)")
bo.nudgeIgnored(); bo.nudgeIgnored()
backoffCheck(bo.requiredGap == 300, "gap caps at 300s", "got \(bo.requiredGap)")
bo.userInteracted()
backoffCheck(bo.requiredGap == 0, "any interaction resets the gap", "got \(bo.requiredGap)")

// Gate behavior: throttled nudge is suppressed and does NOT advance the
// display clock; exempt nudges pass regardless and do advance it.
var bo2 = NudgeBackoff()
for _ in 0..<4 { bo2.nudgeIgnored() }                       // gap now 60s
backoffCheck(bo2.shouldDisplay(urgency: .med, isPositive: false, isFocusType: false, now: 100),
             "first display after backoff passes (no prior display)")
backoffCheck(!bo2.shouldDisplay(urgency: .med, isPositive: false, isFocusType: false, now: 130),
             "nudge inside the 60s gap is suppressed")
backoffCheck(!bo2.shouldDisplay(urgency: .high, isPositive: true, isFocusType: false, now: 131),
             "positive nudges are not exempt")
backoffCheck(bo2.shouldDisplay(urgency: .high, isPositive: false, isFocusType: false, now: 132),
             "high-urgency correction breaks through")
backoffCheck(bo2.shouldDisplay(urgency: .low, isPositive: false, isFocusType: true, now: 133),
             "focus-goal nudge breaks through")
var bo3 = NudgeBackoff()
for _ in 0..<4 { bo3.nudgeIgnored() }
_ = bo3.shouldDisplay(urgency: .med, isPositive: false, isFocusType: false, now: 100)
_ = bo3.shouldDisplay(urgency: .med, isPositive: false, isFocusType: false, now: 130) // suppressed
backoffCheck(bo3.shouldDisplay(urgency: .med, isPositive: false, isFocusType: false, now: 161),
             "suppressed display doesn't advance the clock (161 - 100 >= 60)")

// Coaching-note parsing: structured blocks, freeform prose mentions, and
// legacy-id normalization all resolve to canonical signal types.
func parseCheck(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("notes \(label): \(ok ? "PASS" : "FAIL\(detail.isEmpty ? "" : " — \(detail)")")")
    if !ok { fail = true }
}

let structured = TrainingStore.parseFeedback("""
Signal: hedge_not_pinned
Evidence: "I could maybe do it by Friday"
Nudge: Pin the exact date

Trigger 2: talkTime
Evidence: monologued for 90 seconds about pricing
Nudge: Hand the floor back
""")
parseCheck(structured.map(\.signalId) == ["hedgeNotPinned", "talkTime"],
           "structured blocks parse to canonical ids", "got \(structured.map(\.signalId))")
parseCheck(structured.first?.nudge == "Pin the exact date",
           "structured nudge text survives", "got \(structured.first?.nudge ?? "nil")")

let prose = TrainingStore.parseFeedback("""
What worked: you noticed when they went quiet after the pricing ask.
You kept stacking questions — one question at a time next time.
The Wednesday commitment was a hedge, should have pinned it in the room.
""")
let proseTypes = Set(prose.map(\.signalId))
parseCheck(proseTypes.contains("stackedQuestions") && proseTypes.contains("hedgeNotPinned"),
           "freeform prose mentions are captured", "got \(proseTypes.sorted())")

parseCheck(TrainingStore.canonicalType(for: "talk_time_imbalance") == .talkTime
           && TrainingStore.canonicalType(for: "unaddressed_objection") == .buriedSignal
           && TrainingStore.canonicalType(for: "no_decision") == .noDecision,
           "legacy and semantic ids normalize to current types")

parseCheck(TrainingStore.parseFeedback("Great meeting, keep the energy up!").isEmpty,
           "notes naming no signal parse to nothing")

exit(fail ? 1 : 0)
