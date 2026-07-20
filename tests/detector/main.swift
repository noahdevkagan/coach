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

// 9. Armed live session: the meeting's mic hold released → ended fires
//    60s after the release and keeps firing every tick while the release
//    persists (the service vetoes stops mid-goodbye, so a one-shot event
//    could be swallowed). The detector stays live until the service
//    acknowledges the stop via sessionEnded().
var d9 = MeetingDetector()
d9.sessionStarted()
let e9 = runEnded([(0, app), (100, quiet)], detector: &d9, to: 300)
check(e9.first == 160, "meeting end fires 60s after mic release", "got \(e9.prefix(3))")
check(e9 == Array(stride(from: 160.0, through: 300, by: 1)),
      "ended keeps firing while the release persists", "got \(e9.count) events")
check(d9.isLive, "detector stays live until the stop is acknowledged", "got \(d9.state)")

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

// 12. After an auto-end (service acknowledges via sessionEnded) the
//     detector prompts again for the next meeting.
var d12 = MeetingDetector()
d12.sessionStarted()
_ = runEnded([(0, app), (100, quiet)], detector: &d12, to: 200)
d12.sessionEnded()   // what the service does once the session stops
let p12 = run([(300, app)], detector: &d12, from: 250, to: 330)
check(p12 == [305], "prompts again for the next meeting", "got \(p12)")

// 12b. Regression (2026-07-20 William meeting): the service vetoes the
//      first .ended reports because goodbyes were <20s ago — the detector
//      must KEEP reporting the end so a later re-check can stop the
//      session. And if the meeting resumes (mic evidence back), the
//      pending end cancels; a second release restarts the debounce.
var d12b = MeetingDetector()
d12b.sessionStarted()
let e12b = runEnded([(0, app), (100, quiet), (200, app), (250, quiet)],
                    detector: &d12b, to: 400)
check(e12b.first == 160 && e12b.contains(199) && !e12b.contains(200),
      "end reports persist through a veto; resuming mic cancels them", "got \(e12b.prefix(45))")
check(e12b.filter { $0 >= 200 }.first == 310,
      "second release restarts the 60s debounce (ended at 250+60)",
      "got \(e12b.filter { $0 >= 200 }.first ?? -1)")

// MARK: - Window evidence

/// Copy of `s` with the tri-state window evidence set.
func win(_ s: MeetingSignals, _ w: Bool?) -> MeetingSignals {
    var c = s
    c.meetingWindowPresent = w
    return c
}

/// Tick 1s steps; return every non-.none event with its time.
func runEvents(_ timeline: [(Double, MeetingSignals)], detector: inout MeetingDetector,
               from start: Double = 0, to end: Double) -> [(Double, MeetingDetector.Event)] {
    var events: [(Double, MeetingDetector.Event)] = []
    var t = start
    while t <= end {
        let signals = timeline.last(where: { $0.0 <= t })?.1 ?? quiet
        let e = detector.tick(signals, now: t)
        if e != .none { events.append((t, e)) }
        t += 1
    }
    return events
}

// 13. Both end signals agree (mic released AND meeting window gone) →
//     confident end after the short 15s debounce, not 60s.
var d13 = MeetingDetector()
d13.sessionStarted()
let e13 = runEnded([(0, win(app, true)), (100, win(quiet, false))], detector: &d13, to: 300)
check(e13.first == 115, "mic release + window gone ends at 15s", "got \(e13.prefix(3))")

// 14. Muted participant: mic released but the meeting window persists →
//     never auto-ends; fires .endedAmbiguous at 300s, stays live, and
//     re-fires 300s later while the situation persists.
var d14 = MeetingDetector()
d14.sessionStarted()
let ev14 = runEvents([(0, win(app, true)), (100, win(quiet, true))], detector: &d14, to: 750)
check(ev14.map(\.1) == [.endedAmbiguous, .endedAmbiguous]
      && ev14.map(\.0) == [400, 700],
      "window persists → ambiguous at 300s, re-fires, never .ended", "got \(ev14)")
check(d14.isLive, "ambiguous end leaves the session live", "got \(d14.state)")

// 15. A meeting window arms a session whose mic was never attributed
//     (muted browser participant) — window disappearing then ends it.
var d15 = MeetingDetector()
d15.sessionStarted()
let e15 = runEnded([(0, win(quiet, true)), (50, win(quiet, false))], detector: &d15, to: 300)
check(e15.first == 50, "window evidence arms and ends an unattributed session", "got \(e15.prefix(3))")

// 16. Window gone but the app still holds the mic warm (Zoom/Slack
//     post-call) → ends after the 90s linger debounce.
var d16 = MeetingDetector()
d16.sessionStarted()
let e16 = runEnded([(0, win(app, true)), (100, win(app, false))], detector: &d16, to: 400)
check(e16.first == 190, "mic lingering after window gone ends at 90s", "got \(e16.prefix(3))")

// 17. Fail-safe: absence is only trusted after a window was SEEN — false
//     from the start (heuristic never matched) behaves exactly like the
//     mic-only 60s path of test 9.
var d17 = MeetingDetector()
d17.sessionStarted()
let e17 = runEnded([(0, win(app, false)), (100, win(quiet, false))], detector: &d17, to: 300)
check(e17.first == 160, "unseen window absence degrades to the 60s mic path", "got \(e17.prefix(3))")

// 18. Window flapping right after a mic release (Space switch) under the
//     fast debounce doesn't end the session; the persistent-window
//     ambiguous path takes over.
var d18 = MeetingDetector()
d18.sessionStarted()
let ev18 = runEvents([(0, win(app, true)), (100, win(quiet, true)),
                      (105, win(quiet, false)), (110, win(quiet, true))],
                     detector: &d18, to: 500)
check(!ev18.map(\.1).contains(.ended) && ev18.contains(where: { $0.1 == .endedAmbiguous }),
      "brief window flap doesn't end; ambiguous path resumes", "got \(ev18)")

// 19. End signals compound: 40s into the mic-quiet 60s wait the window
//     disappears → threshold drops to 15s (already exceeded) → immediate.
var d19 = MeetingDetector()
d19.sessionStarted()
let e19 = runEnded([(0, win(app, true)), (100, win(quiet, nil)), (140, win(quiet, false))],
                   detector: &d19, to: 300)
check(e19.first == 140, "window vanishing mid-quiet ends immediately", "got \(e19.prefix(3))")

// MARK: - Window heuristics (pure title/owner matching)

let zoomWin = WindowInfo(ownerName: "zoom.us", title: "Zoom Meeting")
let huddleWin = WindowInfo(ownerName: "Slack", title: "Huddle with growth team")
let meetWin = WindowInfo(ownerName: "Google Chrome", title: "Meet – xyz-abcd-efg")
let docWin = WindowInfo(ownerName: "Google Chrome", title: "Q3 plan - Google Docs")

check(MeetingWindowHeuristics.evaluate(windows: [docWin, zoomWin], zoomRunning: true,
                                       slackRunning: false, micHolderIsBrowser: false) == true,
      "zoom meeting window matches")
check(MeetingWindowHeuristics.evaluate(windows: [docWin], zoomRunning: true,
                                       slackRunning: false, micHolderIsBrowser: false) == false,
      "zoom running without meeting window is decisive absence")
check(MeetingWindowHeuristics.evaluate(windows: [huddleWin], zoomRunning: false,
                                       slackRunning: true, micHolderIsBrowser: false) == true,
      "slack huddle window matches")
check(MeetingWindowHeuristics.evaluate(windows: [meetWin], zoomRunning: false,
                                       slackRunning: false, micHolderIsBrowser: true) == true,
      "meet tab title matches")
check(MeetingWindowHeuristics.evaluate(windows: [docWin], zoomRunning: false,
                                       slackRunning: false, micHolderIsBrowser: true) == nil,
      "browser absence is never decisive (active-tab titles)")
check(MeetingWindowHeuristics.evaluate(windows: [docWin], zoomRunning: true,
                                       slackRunning: false, micHolderIsBrowser: true) == nil,
      "zoom idling while the meeting is in a browser stays unknown")

exit(fail ? 1 : 0)
