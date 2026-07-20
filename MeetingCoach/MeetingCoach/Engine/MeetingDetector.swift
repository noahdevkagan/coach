import Foundation

/// Sampled environment signals the detector reasons over. Adapters fill
/// this in (CoreAudio mic state, NSWorkspace app list); the state machine
/// itself is pure and unit-tested.
struct MeetingSignals: Equatable, Sendable {
    /// Some process holds the default input device open.
    var micInUse = false
    /// A known meeting app (Zoom/Teams/Webex/…) is running.
    var meetingAppRunning = false
    /// A browser is frontmost (Google Meet has no app process to spot);
    /// gets a much longer debounce since browsers are always around.
    var browserFrontmost = false
    /// Tri-state window evidence: true = a meeting window (Zoom meeting,
    /// Slack huddle, Meet tab title) is on screen; false = the sampler ran
    /// and found none; nil = unknown (no Screen Recording permission, or
    /// not sampled this tick). `false` is only trusted once a window was
    /// seen during the current live session — a heuristic that never
    /// matches degrades to mic-only behavior, never to a false end.
    var meetingWindowPresent: Bool? = nil
}

/// Decides when to ask "Meeting detected — start coaching?". Detection
/// never starts capture — it only raises one prompt per sustained meeting,
/// with a cooldown after a dismissal so it can't nag.
struct MeetingDetector: Sendable {
    /// Signals must hold this long before prompting (meeting app present).
    var appDebounce: TimeInterval = 5
    /// Browser-only evidence needs much longer to be believable.
    var browserDebounce: TimeInterval = 20
    /// Quiet period after the user dismisses a prompt.
    var dismissCooldown: TimeInterval = 600
    /// Once a session is live, the meeting's mic hold must stay released
    /// this long before the meeting counts as over — brief drops (device
    /// switch, reconnect) must not end a live session. This is the
    /// no-window-information path; window evidence picks a different
    /// debounce below.
    var endDebounce: TimeInterval = 60
    /// Mic released AND the meeting window is gone — both independent end
    /// signals agree, so end with confidence.
    var fastEndDebounce: TimeInterval = 15
    /// Mic released BUT the meeting window is still on screen (muted
    /// participant — some browsers drop the mic hold while muted). Never
    /// auto-ends; fires `.endedAmbiguous` after this long instead.
    var windowHoldEndDebounce: TimeInterval = 300
    /// Meeting window gone BUT the app still holds the mic warm (Zoom and
    /// Slack keep the input open after a call on some versions).
    var micLingerEndDebounce: TimeInterval = 90

    enum State: Equatable, Sendable {
        case idle
        case candidate(since: TimeInterval, viaApp: Bool)
        /// Prompt raised — no further prompts until the meeting signals
        /// fully drop.
        case prompted
        /// A coaching session is running. `armed` flips true once a meeting
        /// app/browser is seen holding the mic (or a meeting window is
        /// seen); only an armed session can auto-end (in-person sessions
        /// with no meeting signals never arm). `windowSeen` latches once a
        /// meeting window was observed, and gates whether window absence
        /// counts as end evidence.
        case live(armed: Bool, windowSeen: Bool, quietSince: TimeInterval?)
        case cooldown(until: TimeInterval)
    }
    enum Event: Equatable, Sendable {
        case none, prompt, ended
        /// Mic long released but a meeting window is still visible — too
        /// ambiguous to auto-stop. The session stays live; the service may
        /// surface a gentle hint but must not stop the session.
        case endedAmbiguous
    }

    private(set) var state: State = .idle

    mutating func tick(_ signals: MeetingSignals, now: TimeInterval) -> Event {
        let candidate = signals.micInUse && (signals.meetingAppRunning || signals.browserFrontmost)

        switch state {
        case .idle:
            if candidate {
                state = .candidate(since: now, viaApp: signals.meetingAppRunning)
            }
        case .candidate(let since, let viaApp):
            // The mic staying hot is what sustains candidacy — app/browser
            // evidence is only needed to START it. A browser losing
            // frontmost mid-debounce (screenshot tool, quick app switch
            // right after joining a Meet) must not reset the clock.
            if !signals.micInUse {
                state = .idle
            } else {
                // A meeting app appearing mid-candidacy upgrades to the
                // shorter debounce; it never downgrades.
                let viaAppNow = viaApp || signals.meetingAppRunning
                if now - since >= (viaAppNow ? appDebounce : browserDebounce) {
                    state = .prompted
                    return .prompt
                }
                state = .candidate(since: since, viaApp: viaAppNow)
            }
        case .prompted:
            // Meeting over (mic released) → rearm for the next one.
            if !signals.micInUse { state = .idle }
        case .live(let armed, let windowSeen, let quietSince):
            let nowWindowSeen = windowSeen || signals.meetingWindowPresent == true
            let nowArmed = armed || candidate || signals.meetingWindowPresent == true
            let windowGone = nowWindowSeen && signals.meetingWindowPresent == false
            // End evidence: the meeting's mic hold dropped, OR the meeting
            // window vanished while the app keeps the mic warm (Zoom/Slack
            // hold the input open after a call on some versions).
            if nowArmed && (!candidate || windowGone) {
                let since = quietSince ?? now
                if candidate {
                    // Mic warm, window gone.
                    if now - since >= micLingerEndDebounce {
                        state = .idle
                        return .ended
                    }
                } else if windowGone {
                    // Both end signals agree — end fast.
                    if now - since >= fastEndDebounce {
                        state = .idle
                        return .ended
                    }
                } else if nowWindowSeen && signals.meetingWindowPresent == true {
                    // Mic released but the meeting window persists — the
                    // muted-participant case. Never auto-end; surface an
                    // ambiguous event and keep the quiet clock rolling so
                    // it can re-fire if the situation persists.
                    if now - since >= windowHoldEndDebounce {
                        state = .live(armed: nowArmed, windowSeen: nowWindowSeen, quietSince: now)
                        return .endedAmbiguous
                    }
                } else {
                    // No window information — the original mic-only path.
                    if now - since >= endDebounce {
                        state = .idle
                        return .ended
                    }
                }
                state = .live(armed: nowArmed, windowSeen: nowWindowSeen, quietSince: since)
            } else {
                state = .live(armed: nowArmed, windowSeen: nowWindowSeen, quietSince: nil)
            }
        case .cooldown(let until):
            if now >= until {
                state = .idle
                // Re-enter immediately if a meeting is still/again live.
                return tick(signals, now: now)
            }
        }
        return .none
    }

    /// User dismissed the prompt — stay quiet for the cooldown.
    mutating func dismissed(now: TimeInterval) {
        state = .cooldown(until: now + dismissCooldown)
    }

    /// A session started (from the prompt or manually) — watch the meeting
    /// signals so a sustained mic release can end it.
    mutating func sessionStarted() {
        state = .live(armed: false, windowSeen: false, quietSince: nil)
    }

    /// The session was stopped by the user — suppress prompting until the
    /// meeting signals fully drop, then rearm for the next meeting.
    mutating func sessionEnded() {
        state = .prompted
    }

    var isLive: Bool {
        if case .live = state { return true }
        return false
    }

    mutating func reset() {
        state = .idle
    }
}
