import Foundation

/// The give-MeetMouse-to-a-friend loop: every user gets 3 invites to
/// hand out. One shared AppSumo redemption code — the count is a local
/// honor-system nudge (scarcity drives sharing), not an enforcement.
/// Nothing here touches the network; the invite is copied text.
enum ReferralInvites {
    static let totalInvites = 3

    // Defaults-overridable so the code/link can be corrected without a
    // release: `defaults write com.coach.MeetingCoach referralCode NEWCODE`.
    static var code: String {
        UserDefaults.standard.string(forKey: "referralCode") ?? "coachfree"
    }
    static var redeemURL: String {
        UserDefaults.standard.string(forKey: "referralRedeemURL")
            ?? "https://appsumo.com/products/meeting-coach/"
    }

    /// The ready-to-paste invite. First person, short, and the friend's
    /// payoff (free, on-device) up front — written to survive being pasted
    /// into Slack, iMessage, or email unedited.
    static var inviteMessage: String {
        """
        I've been using MeetMouse — an AI meeting coach that runs 100% on your Mac (nothing leaves your machine). It nudges you live when you're rambling, interrupting, or missing a buying signal.

        I get a few free copies to give away and thought of you. Redeem yours free on AppSumo with code \(code): \(redeemURL)
        """
    }

    static var invitesLeft: Int {
        get {
            UserDefaults.standard.object(forKey: "referralInvitesLeft") as? Int ?? totalInvites
        }
        set {
            UserDefaults.standard.set(max(0, newValue), forKey: "referralInvitesLeft")
        }
    }

    /// Copying the invite spends one (floor 0 — giving is always allowed,
    /// the count exists for urgency, not enforcement).
    static func consumeInvite() {
        invitesLeft -= 1
    }

    /// Whether the one-time "give it to a friend" moment has already been
    /// shown. Key name says "first session" for history: the prompt used to
    /// fire after the first real meeting and now waits for the second, but
    /// anyone who already saw it under the old rule must never see it again.
    static var firstSessionPromptShown: Bool {
        get { UserDefaults.standard.bool(forKey: "referralFirstSessionPromptShown") }
        set { UserDefaults.standard.set(newValue, forKey: "referralFirstSessionPromptShown") }
    }

    /// Completed real (non-demo) coached meetings. Seeded on first read
    /// from the saved session files so existing users' history counts —
    /// someone with five sessions on disk is past the prompt threshold,
    /// not "new" because the counter key didn't exist yet.
    static var completedMeetingCount: Int {
        get {
            if let n = UserDefaults.standard.object(forKey: "referralCompletedMeetingCount") as? Int {
                return n
            }
            let seeded = TranscriptSearch.sessionFiles().count
            UserDefaults.standard.set(seeded, forKey: "referralCompletedMeetingCount")
            return seeded
        }
        set { UserDefaults.standard.set(newValue, forKey: "referralCompletedMeetingCount") }
    }
}
