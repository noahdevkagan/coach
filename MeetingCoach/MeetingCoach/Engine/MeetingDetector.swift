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
    /// switch, reconnect) must not end a live session.
    var endDebounce: TimeInterval = 60

    enum State: Equatable, Sendable {
        case idle
        case candidate(since: TimeInterval, viaApp: Bool)
        /// Prompt raised — no further prompts until the meeting signals
        /// fully drop.
        case prompted
        /// A coaching session is running. `armed` flips true once a meeting
        /// app/browser is seen holding the mic; only an armed session can
        /// auto-end (in-person sessions with no meeting signals never arm).
        case live(armed: Bool, quietSince: TimeInterval?)
        case cooldown(until: TimeInterval)
    }
    enum Event: Equatable, Sendable { case none, prompt, ended }

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
        case .live(let armed, let quietSince):
            if candidate {
                state = .live(armed: true, quietSince: nil)
            } else if armed {
                let since = quietSince ?? now
                if now - since >= endDebounce {
                    state = .idle
                    return .ended
                }
                state = .live(armed: true, quietSince: since)
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
        state = .live(armed: false, quietSince: nil)
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
