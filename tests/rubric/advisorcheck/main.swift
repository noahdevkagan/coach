import Foundation

// RubricAdvisor rule checks — fixture evidence in, exact expected proposals
// out. The rules are deterministic on purpose so this stays golden-able.

var fail = false
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("\(label): \(ok ? "PASS" : "FAIL\(detail.isEmpty ? "" : " — \(detail)")")")
    if !ok { fail = true }
}

typealias E = RubricAdvisor.SignalEvidence

// 1. Wrong-heavy signal → disable.
var wrongHeavy = E(key: "hedgeNotPinned")
wrongHeavy.rated = 10; wrongHeavy.wrong = 8; wrongHeavy.sessionsWithSignal = 4
check(RubricAdvisor.proposal(for: wrongHeavy)?.kind == .disable,
      "wrong-heavy -> disable")

// 2. Meh-heavy built-in → raiseCooldown; Meh-heavy custom → disable.
var mehBuiltin = E(key: "talkTime")
mehBuiltin.rated = 6; mehBuiltin.annoying = 4; mehBuiltin.sessionsWithSignal = 3
check(RubricAdvisor.proposal(for: mehBuiltin)?.kind == .raiseCooldown,
      "meh-heavy builtin -> raiseCooldown")

var mehCustom = E(key: "custom:rambling_intro")
mehCustom.rated = 6; mehCustom.annoying = 4; mehCustom.sessionsWithSignal = 3
check(RubricAdvisor.proposal(for: mehCustom)?.kind == .disable,
      "meh-heavy custom -> disable")

// 3. Useful-heavy built-in → moreSensitive; customs never get moreSensitive.
var usefulHeavy = E(key: "questionLanded")
usefulHeavy.rated = 5; usefulHeavy.useful = 5; usefulHeavy.sessionsWithSignal = 3
check(RubricAdvisor.proposal(for: usefulHeavy)?.kind == .moreSensitive,
      "useful-heavy builtin -> moreSensitive")

var usefulCustom = E(key: "custom:crisp_open")
usefulCustom.rated = 5; usefulCustom.useful = 5; usefulCustom.sessionsWithSignal = 3
check(RubricAdvisor.proposal(for: usefulCustom) == nil,
      "useful-heavy custom -> no proposal")

// 4. Below evidence floors → silence.
var thin = E(key: "interruption")
thin.rated = 4; thin.wrong = 4; thin.sessionsWithSignal = 4
check(RubricAdvisor.proposal(for: thin) == nil, "under min rated -> nil")

var fewSessions = E(key: "interruption")
fewSessions.rated = 10; fewSessions.wrong = 9; fewSessions.sessionsWithSignal = 2
check(RubricAdvisor.proposal(for: fewSessions) == nil, "under min sessions -> nil")

// 5. Adaptive multiplier pinned at ceiling + still firing → disable,
//    even with no explicit ratings; not firing recently → silence.
var pinned = E(key: "vagueAnswer")
pinned.sessionsWithSignal = 5; pinned.adaptiveMultiplier = 2.0; pinned.firedInRecentSessions = true
check(RubricAdvisor.proposal(for: pinned)?.kind == .disable, "pinned adaptive -> disable")

var pinnedQuiet = pinned
pinnedQuiet.firedInRecentSessions = false
check(RubricAdvisor.proposal(for: pinnedQuiet) == nil, "pinned but quiet -> nil")

// 6. Evidence aggregation across sessions (per-key rated/wrong counts and
//    session tally; adaptive fields come from live state, not asserted).
func session(keyCounts: [String: Int], feedback: [String: [NudgeFeedback: Int]]) -> SessionSummary {
    SessionSummary(date: Date(timeIntervalSinceReferenceDate: 0),
                   durationFormatted: "30:00", utteranceCount: 100,
                   nudgeCounts: [:], totalNudges: keyCounts.values.reduce(0, +),
                   feedbackCounts: [:], talkShare: 0.5,
                   nudgeKeyCounts: keyCounts, feedbackByKey: feedback,
                   durationMinutes: 30)
}
let sessions = [
    session(keyCounts: ["talkTime": 2], feedback: ["talkTime": [.wrong: 2]]),
    session(keyCounts: ["talkTime": 1, "custom:x": 1], feedback: ["talkTime": [.wrong: 1, .useful: 1]]),
    session(keyCounts: ["talkTime": 3], feedback: [:]),
]
let evidence = RubricAdvisor.evidence(from: sessions)
let talk = evidence.first { $0.key == "talkTime" }
check(talk?.sessionsWithSignal == 3 && talk?.rated == 4 && talk?.wrong == 3 && talk?.useful == 1,
      "evidence aggregation",
      "got \(String(describing: talk))")

exit(fail ? 1 : 0)
