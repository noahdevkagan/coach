import Foundation

// EchoFilter behavior checks (pure logic, no audio). The filter is what
// keeps the far side's voice — leaking speakers → mic — out of the "You"
// channel, sentence by sentence. Validated against the real 2026-07-14
// session: whole-chunk overlap suppression left 3,771 far-side words in
// "You" (62% WER); this filter cut that to 481 (13.5% WER) on replay.

var fail = false
func check(_ name: String, _ ok: Bool) {
    print("echo \(name): \(ok ? "PASS" : "FAIL")")
    if !ok { fail = true }
}

let base = Date(timeIntervalSinceReferenceDate: 1_000)
func at(_ t: TimeInterval) -> Date { base.addingTimeInterval(t) }

// 1. A mic chunk mixing an echoed sentence with genuine speech keeps only
//    the genuine part, and reports the kept fraction for span scaling.
do {
    let f = EchoFilter()
    var now = at(0); f.clock = { now }
    f.recordFarText("My husband's nerdy about tracking water levels and yard health.")
    now = at(4)
    let r = f.filter("My husband is nerdy about tracking water levels and yard health. Is he excited about the free water?",
                     since: at(-3))
    check("strips echoed sentence", r?.text == "Is he excited about the free water?")
    check("reports kept fraction", r.map { $0.keptFraction > 0 && $0.keptFraction < 1 } ?? false)
}

// 2. A chunk that is entirely echo is dropped outright.
do {
    let f = EchoFilter()
    var now = at(0); f.clock = { now }
    f.recordFarText("we just got an inch in forty six minutes")
    now = at(2)
    check("drops all-echo chunk",
          f.filter("We just got an inch in 46 minutes.", since: at(-3)) == nil)
}

// 3. Genuine speech with no far-side overlap passes through untouched.
do {
    let f = EchoFilter()
    f.recordFarText("the quarterly numbers look strong across every region")
    let r = f.filter("I want to talk about hiring for the sales team.", since: at(-3))
    check("keeps genuine speech", r?.text == "I want to talk about hiring for the sales team." && r?.keptFraction == 1.0)
}

// 4. Short backchannels ("Okay.", "Yeah.") are never classified as echo,
//    even when the far side just said the same words.
do {
    let f = EchoFilter()
    f.recordFarText("okay yeah that sounds right")
    let r = f.filter("Okay. Yeah.", since: at(-3))
    check("keeps short backchannels", r?.text == "Okay. Yeah.")
}

// 5. The pool is time-windowed: far-side words heard before `since` can't
//    be the source of this chunk's echo.
do {
    let f = EchoFilter()
    var now = at(0); f.clock = { now }
    f.recordFarText("my husband is nerdy about tracking water levels")
    now = at(60)
    let r = f.filter("My husband is nerdy about tracking water levels.", since: at(30))
    check("ignores stale far words", r?.keptFraction == 1.0)
}

// 6. Partials feed the pool incrementally (whole growing window each tick,
//    only the new suffix is added) — so echo is caught even before the far
//    pipeline commits.
do {
    let f = EchoFilter()
    var now = at(0); f.clock = { now }
    f.recordFarPartial("we got an")
    now = at(1)
    f.recordFarPartial("we got an inch this morning")
    now = at(3)
    check("pools partial deltas",
          f.filter("We got an inch this morning.", since: at(-3)) == nil)
}

exit(fail ? 1 : 0)
