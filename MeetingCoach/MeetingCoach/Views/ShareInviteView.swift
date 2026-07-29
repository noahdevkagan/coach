import SwiftUI
import AppKit

/// The free-copy invite: Meeting Coach's one growth loop.
///
/// Two entry points, one panel — a sheet right after the user's first real
/// session (the moment the app has actually proven itself), and a permanent
/// menu bar item for every time after that.
///
/// Local-first holds here too: the buttons copy text, open the user's
/// browser, or hand a prefilled draft to their mail client. The app itself
/// makes no network call and counts nothing.
enum ShareInvite {
    static let pageURL = "http://appsumo.com/products/meeting-coach"
    static let redeemCode = "CoachFree"

    /// What a colleague reads in the DM / inbox. Written as the user, not
    /// as the app — this gets pasted verbatim.
    static let message = """
        I've been using Meeting Coach on my calls — live transcript, an \
        automatic recap afterwards, and it nudges me in the moment when I'm \
        talking too much or skipping a question. Runs entirely on your Mac; \
        no audio ever leaves it.

        It's free for you here: \(pageURL)
        Redeem with code: \(redeemCode)
        """

    static let emailSubject = "A free copy of Meeting Coach"

    static func openPage() {
        guard let url = URL(string: pageURL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Prefilled draft in the default mail client — recipients and Send stay
    /// with the user. Built through URLComponents so the newlines in the
    /// body are percent-encoded rather than truncating the mailto.
    static func composeEmail() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.queryItems = [
            URLQueryItem(name: "subject", value: emailSubject),
            URLQueryItem(name: "body", value: message),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }
}

struct ShareInviteView: View {
    /// Post-session presentation earns a different opening line ("you just
    /// ran your first session") than the always-available menu bar one.
    var isFirstSessionPrompt = false

    @Environment(\.dismiss) private var dismiss
    @State private var inviteCopied = false
    @State private var codeCopied = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "gift.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [.green, .green.opacity(0.75)],
                                             startPoint: .top, endPoint: .bottom))
                )

            Text(isFirstSessionPrompt
                 ? "That's your first meeting coached"
                 : "Give Meeting Coach away")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(isFirstSessionPrompt
                 ? "Pass it on — anyone you send this to gets Meeting Coach free. No trial, no card, same app you just used."
                 : "Anyone you send this to gets Meeting Coach free. No trial, no card, same app you use.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("REDEEM CODE")
                        .font(.caption2.weight(.semibold))
                        .kerning(0.9)
                        .foregroundStyle(.tertiary)
                    Text(ShareInvite.redeemCode)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                }
                Spacer()
                Button(codeCopied ? "Copied" : "Copy") {
                    RecapExporter.copyToPasteboard(ShareInvite.redeemCode)
                    codeCopied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        codeCopied = false
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 400)
            .cardStyle()

            HStack(spacing: 12) {
                Button(isFirstSessionPrompt ? "Not now" : "Done") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                Button {
                    RecapExporter.copyToPasteboard(ShareInvite.message)
                    inviteCopied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        inviteCopied = false
                    }
                } label: {
                    Label(inviteCopied ? "Invite copied" : "Copy invite",
                          systemImage: inviteCopied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.green)
                .keyboardShortcut(.defaultAction)
                .help("Copies a short message with the link and the code — paste it into Slack, iMessage, wherever.")
            }
            .padding(.top, 2)

            HStack(spacing: 18) {
                Button("Email it…") { ShareInvite.composeEmail() }
                    .buttonStyle(.link)
                Button("Open the page") { ShareInvite.openPage() }
                    .buttonStyle(.link)
            }
            .font(.callout)
        }
        .padding(32)
        .frame(width: 480)
    }
}
