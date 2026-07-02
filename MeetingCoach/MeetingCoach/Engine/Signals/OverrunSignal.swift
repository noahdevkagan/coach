import Foundation

/// Signal #12: Fires when the meeting blows past its scheduled end. The
/// time-boxed signals (timeCheck, nextSteps) disarm at the scheduled end —
/// which is exactly when "you're overrunning" coaching matters most. A
/// 15-minute check-in that runs to 33 ends rushed, with the biggest topics
/// getting the least room.
struct OverrunSignal: SignalMonitor {
    let nudgeType: NudgeType = .overrun

    let scheduledDuration: TimeInterval
    /// First nudge this many seconds past the scheduled end.
    var graceSeconds: TimeInterval = 120
    /// Re-fire cadence while still running (sparse — this is a drumbeat,
    /// not an alarm).
    var repeatEvery: TimeInterval = 600

    private var lastFired: TimeInterval = -.infinity

    init(scheduledMinutes: Int) {
        scheduledDuration = TimeInterval(scheduledMinutes * 60)
    }

    mutating func evaluate(_ input: SignalInput) -> Nudge? {
        guard scheduledDuration > 0 else { return nil }
        let over = input.elapsed - scheduledDuration
        guard over >= graceSeconds else { return nil }
        guard input.elapsed - lastFired >= repeatEvery else { return nil }

        lastFired = input.elapsed
        let overMin = max(1, Int(over / 60))
        return Nudge(
            id: UUID(),
            type: .overrun,
            text: "\(overMin)min over — land it or rebook",
            urgency: .high,
            timestamp: input.elapsed
        )
    }

    mutating func reset() {
        lastFired = -.infinity
    }
}
