import Foundation

/// Session-scoped overlay fatigue guard. Consecutive full-timeout ignores
/// stretch the minimum gap between overlay displays — someone who isn't
/// engaging gets nudged less, not louder — and any explicit feedback
/// (useful, annoying, wrong) snaps the cadence back to normal. Suppressed
/// nudges still land in the feed and the recap; only the overlay throttles.
/// Pure — compiled into the tests/nudges sigcheck binary.
struct NudgeBackoff: Sendable {
    /// Ignores in a row before any throttling starts.
    var freeIgnores = 3
    /// Gap after the first throttled level; doubles per further ignore.
    var baseGap: TimeInterval = 60
    var maxGap: TimeInterval = 300

    private(set) var consecutiveIgnores = 0
    private(set) var lastDisplayAt: TimeInterval?

    /// A displayed nudge timed out with no interaction.
    mutating func nudgeIgnored() {
        consecutiveIgnores += 1
    }

    /// The user touched a nudge (any feedback, overlay or feed).
    mutating func userInteracted() {
        consecutiveIgnores = 0
    }

    /// Minimum time since the last overlay display before showing another:
    /// 0 while under `freeIgnores`, then baseGap · 2^(extra ignores), capped.
    var requiredGap: TimeInterval {
        let over = consecutiveIgnores - freeIgnores
        guard over > 0 else { return 0 }
        return min(baseGap * pow(2, Double(over - 1)), maxGap)
    }

    /// Whether this nudge may claim the overlay. High-urgency corrections
    /// and the user's focus goals always break through; everything else —
    /// positive reinforcement included, praise is the cheapest thing to cut
    /// under demonstrated fatigue — waits out the current gap.
    mutating func shouldDisplay(urgency: NudgeUrgency, isPositive: Bool,
                                isFocusType: Bool, now: TimeInterval) -> Bool {
        let exempt = (urgency == .high && !isPositive) || isFocusType
        if !exempt, let last = lastDisplayAt, now - last < requiredGap {
            return false
        }
        lastDisplayAt = now
        return true
    }
}
