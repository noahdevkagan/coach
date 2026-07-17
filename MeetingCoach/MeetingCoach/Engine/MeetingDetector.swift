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

    enum State: Equatable, Sendable {
        case idle
        case candidate(since: TimeInterval, viaApp: Bool)
        /// Prompt raised (or a session is running) — no further prompts
        /// until the meeting signals fully drop.
        case prompted
        case cooldown(until: TimeInterval)
    }
    enum Event: Equatable, Sendable { case none, prompt }

    private(set) var state: State = .idle

    mutating func tick(_ signals: MeetingSignals, now: TimeInterval) -> Event {
        let candidate = signals.micInUse && (signals.meetingAppRunning || signals.browserFrontmost)

        switch state {
        case .idle:
            if candidate {
                state = .candidate(since: now, viaApp: signals.meetingAppRunning)
            }
        case .candidate(let since, let viaApp):
            if !candidate {
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
            // Meeting over (signals gone) → rearm for the next one.
            if !candidate { state = .idle }
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

    /// A session started (from the prompt or manually) — suppress prompting
    /// until the meeting signals drop after it ends.
    mutating func sessionStarted() {
        state = .prompted
    }

    mutating func reset() {
        state = .idle
    }
}
