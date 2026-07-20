import Foundation

/// A window snapshot row the heuristics reason over. The service fills
/// these from CGWindowListCopyWindowInfo; kept Foundation-only so the
/// heuristics compile into the detector test binary.
struct WindowInfo: Sendable {
    var ownerName: String
    var title: String
}

/// Pure title/owner matching that turns a window-list snapshot into the
/// tri-state `MeetingSignals.meetingWindowPresent`. English titles only —
/// a localized miss is safe because the detector only trusts absence
/// after it has seen a window at least once (`windowSeen` latch).
enum MeetingWindowHeuristics {
    /// Browser owner names whose window title reflects the active tab.
    static let browserOwners: Set<String> = [
        "Safari", "Google Chrome", "Firefox", "Microsoft Edge", "Brave Browser",
        "Arc", "Vivaldi", "Opera", "Chromium", "Dia", "Comet", "Kagi",
    ]

    /// - Parameters:
    ///   - windows: full window-list snapshot (all Spaces, so minimized or
    ///     other-Space meeting windows don't read as absent).
    ///   - zoomRunning/slackRunning: the app process is alive, so "no
    ///     matching window" is decisive absence for that platform.
    ///   - micHolderIsBrowser: the live meeting's mic evidence came from a
    ///     browser (or is unknown). Browser titles only show the active
    ///     tab, so a missing Meet title is never decisive — the user may
    ///     just have tabbed away.
    /// - Returns: true = meeting window on screen; false = decisively
    ///   absent; nil = can't tell.
    static func evaluate(windows: [WindowInfo],
                         zoomRunning: Bool, slackRunning: Bool,
                         micHolderIsBrowser: Bool) -> Bool? {
        for w in windows {
            if isZoomMeetingWindow(w) || isSlackHuddleWindow(w) || isMeetTabWindow(w) {
                return true
            }
        }
        // No positive match. Only Zoom/Slack absence is decisive (their
        // meeting windows are real windows, not tabs), and only when the
        // meeting's mic isn't held by a browser.
        if (zoomRunning || slackRunning) && !micHolderIsBrowser {
            return false
        }
        return nil
    }

    static func isZoomMeetingWindow(_ w: WindowInfo) -> Bool {
        w.ownerName == "zoom.us"
            && (w.title.hasPrefix("Zoom Meeting") || w.title.hasPrefix("Zoom Webinar"))
    }

    static func isSlackHuddleWindow(_ w: WindowInfo) -> Bool {
        w.ownerName == "Slack" && w.title.localizedCaseInsensitiveContains("huddle")
    }

    static func isMeetTabWindow(_ w: WindowInfo) -> Bool {
        guard browserOwners.contains(w.ownerName) else { return false }
        // Meet tab titles: "Meet – xyz-abcd-ef" (en dash) or hyphen variant.
        return w.title.hasPrefix("Meet – ") || w.title.hasPrefix("Meet - ")
            || w.title.contains("meet.google.com")
    }
}
