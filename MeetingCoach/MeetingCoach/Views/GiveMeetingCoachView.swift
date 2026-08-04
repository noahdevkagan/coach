import SwiftUI
import AppKit

/// "Give MeetingCoach to a friend" — the viral loop. One click copies a
/// ready-to-paste invite (AppSumo code + link); a local 3-invite count
/// adds urgency without ever blocking generosity. Shown two ways: its own
/// window from the menu bar, and a one-time sheet after the user's second
/// real coached meeting (`asSheet`).
struct GiveMeetingCoachView: View {
    /// Sheet mode adds the "aha"-moment framing and a Maybe Later button.
    var asSheet = false

    @Environment(\.dismiss) private var dismiss
    @State private var invitesLeft = ReferralInvites.invitesLeft
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(asSheet ? "Two coached meetings down 🎉"
                             : "Give MeetingCoach to a friend for FREE")
                    .font(.title3.bold())
                Text(asSheet
                     ? "Know someone who talks too much in meetings? You have \(invitesLeft) free \(invitesLeft == 1 ? "copy" : "copies") of MeetingCoach to give away."
                     : "Free for them, redeemed on AppSumo. No forms, no signup — just send the invite.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Invite dots: ●●○ — spent invites hollow out.
            HStack(spacing: 5) {
                ForEach(0..<ReferralInvites.totalInvites, id: \.self) { i in
                    Circle()
                        .fill(i < invitesLeft ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 8, height: 8)
                }
                Text(invitesLeft > 0
                     ? "\(invitesLeft) \(invitesLeft == 1 ? "invite" : "invites") left"
                     : "All invites given — sharing's still allowed 😉")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Text(ReferralInvites.inviteMessage)
                .font(.caption)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.2)))

            HStack {
                if asSheet {
                    Button("Maybe Later") { dismiss() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ReferralInvites.inviteMessage, forType: .string)
                    if !copied {   // multiple copies of one invite spend one
                        ReferralInvites.consumeInvite()
                        invitesLeft = ReferralInvites.invitesLeft
                    }
                    copied = true
                } label: {
                    Label(copied ? "Copied — paste it anywhere" : "Copy Invite",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
