import SwiftUI

/// The post-meeting review card: sectioned Summary / Key Takeaways /
/// Suggested Next Steps with colored icon chips — renders the structured
/// MeetingReview, so no literal markdown ever reaches the user.
struct MeetingReviewView: View {
    let review: MeetingReview
    /// Full shareable recap (summary + session facts + footer). When set,
    /// copy/share controls appear in the card header.
    var recapText: String?
    var onToggleActionItem: ((UUID) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !review.summary.isEmpty {
                section(icon: "text.alignleft", tint: .purple, title: "Summary") {
                    Text(review.summary)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let share = review.talkShare {
                        // Whole-meeting on purpose — the live nudges watch
                        // recent windows; this answers "over the whole call".
                        Text("Whole meeting: you \(Int(share * 100))% · them \(100 - Int(share * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Topic-grouped notes (the Granola-style body). The flat Key
            // Takeaways list only renders for deterministic and pre-0.22
            // reviews — an LLM review carries sections instead.
            ForEach(Array(review.sections.enumerated()), id: \.offset) { _, topic in
                Divider()
                section(icon: "number", tint: .blue, title: topic.heading) {
                    bulletList(topic.bullets)
                }
            }

            if !review.takeaways.isEmpty {
                Divider()
                section(icon: "star.fill", tint: .blue, title: "Key Takeaways") {
                    bulletList(review.takeaways)
                }
            }

            if !review.wins.isEmpty {
                Divider()
                section(icon: "hand.thumbsup.fill", tint: .green, title: "Wins") {
                    bulletList(review.wins)
                }
            }

            if !review.actionItems.isEmpty {
                Divider()
                section(icon: "checkmark.circle.fill", tint: .green, title: "Suggested Next Steps") {
                    ForEach(review.actionItems) { item in
                        Button {
                            onToggleActionItem?(item.id)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: item.isDone ? "checkmark.square.fill" : "square")
                                    .font(.callout)
                                    .foregroundStyle(item.isDone ? Color.green : Color.secondary)
                                Text(item.text)
                                    .font(.callout)
                                    .strikethrough(item.isDone)
                                    .foregroundStyle(item.isDone ? Color.secondary : Color.primary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let focus = review.nextFocus, !focus.isEmpty {
                Divider()
                section(icon: "target", tint: .orange, title: "Next Meeting") {
                    Text(focus)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if review.isDeterministic {
                Text("Instant on-device review — add a local model in Advanced for a deeper AI take.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var header: some View {
        HStack {
            Label("Meeting Review", systemImage: "doc.text.magnifyingglass")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if let recap = recapText {
                CopyButton(help: "Copy recap for Slack or email") { recap }
                ShareLink(item: recap) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Share recap")
            }
        }
    }

    private func bulletList(_ items: [String]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 4, height: 4)
                    .offset(y: -2)
                Text(item)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section(icon: String, tint: Color, title: String,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tint.opacity(0.12))
                    )
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(.leading, 2)
        }
    }
}
