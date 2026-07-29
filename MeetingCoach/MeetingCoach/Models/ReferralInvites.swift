import Foundation

/// The give-MeetingCoach-to-a-friend loop: every user gets 3 invites to
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
        I've been using MeetingCoach — an AI meeting coach that runs 100% on your Mac (nothing leaves your machine). It nudges you live when you're rambling, interrupting, or missing a buying signal.

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

    /// Whether the one-time "give it to a friend" moment after the user's
    /// first real coached meeting has already been shown.
    static var firstSessionPromptShown: Bool {
        get { UserDefaults.standard.bool(forKey: "referralFirstSessionPromptShown") }
        set { UserDefaults.standard.set(newValue, forKey: "referralFirstSessionPromptShown") }
    }
}
