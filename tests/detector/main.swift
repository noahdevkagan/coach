import Foundation

// MeetingDetector state-machine table tests: sequences of sampled signals
// in, exact prompt timing out. Pure logic — no CoreAudio, no AppKit.

var fail = false
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("\(label): \(ok ? "PASS" : "FAIL\(detail.isEmpty ? "" : " — \(detail)")")")
    if !ok { fail = true }
}

let mic = MeetingSignals(micInUse: true, meetingAppRunning: false, browserFrontmost: false)
let app = MeetingSignals(micInUse: true, meetingAppRunning: true, browserFrontmost: false)
let browser = MeetingSignals(micInUse: true, meetingAppRunning: false, browserFrontmost: true)
let quiet = MeetingSignals()

/// Tick 1s steps over a timeline of signals; return prompt times.
func run(_ timeline: [(Double, MeetingSignals)], detector: inout MeetingDetector,
         from start: Double = 0, to end: Double) -> [Double] {
    var prompts: [Double] = []
    var t = start
    while t <= end {
        let signals = timeline.last(where: { $0.0 <= t })?.1 ?? quiet
        if detector.tick(signals, now: t) == .prompt { prompts.append(t) }
        t += 1
    }
    return prompts
}

// 1. Meeting app + mic sustained → one prompt after the 5s debounce.
var d1 = MeetingDetector()
let p1 = run([(0, app)], detector: &d1, to: 60)
check(p1 == [5], "app+mic prompts once at 5s", "got \(p1)")

// 2. Browser-only evidence needs the 20s debounce.
var d2 = MeetingDetector()
let p2 = run([(0, browser)], detector: &d2, to: 60)
check(p2 == [20], "browser+mic prompts once at 20s", "got \(p2)")

// 3. Mic alone never prompts; app alone (mic closed) never prompts.
var d3 = MeetingDetector()
let micOnly = run([(0, mic)], detector: &d3, to: 60)
var d3b = MeetingDetector()
let appNoMic = run([(0, MeetingSignals(micInUse: false, meetingAppRunning: true))], detector: &d3b, to: 60)
check(micOnly.isEmpty && appNoMic.isEmpty, "mic-only / app-without-mic never prompt",
      "got \(micOnly) / \(appNoMic)")

// 4. Signals flapping mid-debounce reset candidacy.
var d4 = MeetingDetector()
let p4 = run([(0, app), (3, quiet), (10, app)], detector: &d4, to: 20)
check(p4 == [15], "flap resets debounce (prompt at 10+5)", "got \(p4)")

// 5. Dismissal starts the 10-min cooldown; with the meeting still live at
//    expiry, candidacy restarts and re-prompts after the debounce.
var d5 = MeetingDetector()
_ = run([(0, app)], detector: &d5, to: 5)          // prompted at t=5
d5.dismissed(now: 6)
let p5 = run([(0, app)], detector: &d5, from: 7, to: 700)
check(p5 == [611], "dismiss quiets for 600s, re-prompts at 606+5", "got \(p5)")

// 6. A live session never prompts; after a manual stop, prompting stays
//    suppressed until signals fully drop, then rearms.
var d6 = MeetingDetector()
d6.sessionStarted()
let p6 = run([(0, app)], detector: &d6, to: 120)
check(p6.isEmpty, "no prompt while session live", "got \(p6)")
d6.sessionEnded()
let p6b = run([(121, quiet), (151, app)], detector: &d6, from: 121, to: 200)
check(p6b == [156], "rearms after signals drop (prompt at 151+5)", "got \(p6b)")

// 7. Meeting app appearing mid-browser-candidacy upgrades to the short
//    debounce, measured from the original candidacy start.
var d7 = MeetingDetector()
let p7 = run([(0, browser), (2, app)], detector: &d7, to: 30)
check(p7 == [5], "browser→app upgrade keeps candidacy start", "got \(p7)")

// 8. Browser candidacy survives the browser losing frontmost (screenshot
//    tool, app switch right after joining a Meet) — the mic staying hot
//    sustains the clock; only the mic dropping resets it.
var d8 = MeetingDetector()
let p8 = run([(0, browser), (5, mic)], detector: &d8, to: 60)
check(p8 == [20], "browser candidacy survives frontmost loss (prompt at 20s)", "got \(p8)")

/// Tick 1s steps over a timeline; return times of .ended events.
func runEnded(_ timeline: [(Double, MeetingSignals)], detector: inout MeetingDetector,
              from start: Double = 0, to end: Double) -> [Double] {
    var ends: [Double] = []
    var t = start
    while t <= end {
        let signals = timeline.last(where: { $0.0 <= t })?.1 ?? quiet
        if detector.tick(signals, now: t) == .ended { ends.append(t) }
        t += 1
    }
    return ends
}

// 9. Armed live session: the meeting's mic hold released → ended exactly
//    once, after the 60s end debounce, leaving the detector idle.
var d9 = MeetingDetector()
d9.sessionStarted()
let e9 = runEnded([(0, app), (100, quiet)], detector: &d9, to: 300)
check(e9 == [160], "meeting end fires 60s after mic release", "got \(e9)")
check(d9.state == .idle, "ended leaves detector idle", "got \(d9.state)")

// 10. A session with no meeting signals (in-person coaching) never arms,
//     so it never auto-ends no matter how long it runs.
var d10 = MeetingDetector()
d10.sessionStarted()
let e10 = runEnded([(0, quiet)], detector: &d10, to: 600)
check(e10.isEmpty, "unarmed session never auto-ends", "got \(e10)")

// 11. Brief mic-hold drops (device switch, reconnect) under the end
//     debounce don't end the session.
var d11 = MeetingDetector()
d11.sessionStarted()
let e11 = runEnded([(0, app), (100, quiet), (130, app)], detector: &d11, to: 400)
check(e11.isEmpty, "sub-debounce mic drop doesn't end the session", "got \(e11)")

// 12. After an auto-end the detector prompts again for the next meeting.
var d12 = MeetingDetector()
d12.sessionStarted()
_ = runEnded([(0, app), (100, quiet)], detector: &d12, to: 200)
let p12 = run([(300, app)], detector: &d12, from: 300, to: 330)
check(p12 == [305], "prompts again for the next meeting", "got \(p12)")

exit(fail ? 1 : 0)
