import Foundation

// Demo choreography gate: replays the bundled demo transcript through the
// REAL TranscriptParser + SignalEngine and asserts the scripted moments
// fire on schedule. The first-launch demo is a product surface — this keeps
// every release's demo showing exactly the coaching it promises.
//
// Usage: democheck <path-to-demo_meeting.txt>

guard CommandLine.arguments.count > 1,
      let text = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) else {
    print("usage: democheck <demo_meeting.txt>")
    exit(2)
}

let utterances = TranscriptParser.parse(text)
guard !utterances.isEmpty else {
    print("demo transcript parsed to zero utterances -> FAIL")
    exit(1)
}

// Replay exactly like the app's demo loop: insert each utterance at its
// scripted time and evaluate; also tick the 1s grid so gap-dependent
// signals (talkTime) fire between utterances.
let context = PreCallContext()
var engine = SignalEngine(context: context)
var fired: [(t: Double, type: NudgeType)] = []
var inserted: [Utterance] = []
var i = 0
let end = (utterances.last?.t ?? 0) + 10
var clock = 0.0
while clock <= end {
    while i < utterances.count, utterances[i].t <= clock {
        inserted.append(utterances[i]); i += 1
    }
    if !inserted.isEmpty {
        for nudge in engine.evaluate(utterances: inserted, elapsed: clock, context: context) {
            fired.append((clock, nudge.type))
        }
    }
    clock += 1
}

var fail = false
func expect(_ type: NudgeType, window: ClosedRange<Double>) {
    if let hit = fired.first(where: { $0.type == type && window.contains($0.t) }) {
        print("demo \(type.rawValue): fired at \(Int(hit.t))s (window \(Int(window.lowerBound))-\(Int(window.upperBound))s) -> PASS")
    } else {
        let actual = fired.filter { $0.type == type }.map { Int($0.t) }
        print("demo \(type.rawValue): \(actual.isEmpty ? "never fired" : "fired at \(actual)s"), wanted \(Int(window.lowerBound))-\(Int(window.upperBound))s -> FAIL")
        fail = true
    }
}

// The five choreographed moments (see Resources/demo_meeting.txt header).
expect(.talkTime, window: 35...50)
expect(.interruption, window: 68...80)
expect(.stackedQuestions, window: 80...90)
expect(.unansweredQuestion, window: 105...115)
expect(.questionLanded, window: 138...150)

// Nag guard: the demo must feel precise, not noisy. Scripted semantic
// nudges (2) come on top of this at runtime.
if fired.count <= 9 {
    print("demo nag cap: \(fired.count) deterministic nudges total (cap 9) -> PASS")
} else {
    print("demo nag cap: \(fired.count) deterministic nudges (cap 9): \(fired.map { "\($0.type.rawValue)@\(Int($0.t))" }) -> FAIL")
    fail = true
}

exit(fail ? 1 : 0)
