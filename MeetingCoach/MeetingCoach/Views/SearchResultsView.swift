import SwiftUI

/// Full-text results over every saved chat: type in the sidebar box, see
/// each moment a word was said, jump to the session file. Grouped by
/// session, newest first — the payoff for "transcript is the product."
struct SearchResultsView: View {
    let query: String
    @State private var hits: [TranscriptHit] = []

    private var groups: [(file: URL, title: String, hits: [TranscriptHit])] {
        var order: [URL] = []
        var byFile: [URL: [TranscriptHit]] = [:]
        for hit in hits {
            if byFile[hit.file] == nil { order.append(hit.file) }
            byFile[hit.file, default: []].append(hit)
        }
        return order.map { (file: $0, title: TranscriptSearch.title(for: $0), hits: byFile[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Search")
                    .font(MCTheme.paneTitle)
                Text("“\(query)”")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if !hits.isEmpty {
                    Text("\(groups.count) chats · \(hits.count) mentions")
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
            Divider().opacity(0.5)

            if hits.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.title2).foregroundStyle(.tertiary)
                    Text("No mentions of “\(query)” in saved chats")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups, id: \.file) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(group.title)
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Open") {
                                        NSWorkspace.shared.open(group.file)
                                    }
                                    .font(.caption)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.blue)
                                    .help("Open the saved transcript")
                                }
                                ForEach(group.hits) { hit in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(hit.timestamp)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                        Text(hit.speaker)
                                            .font(.caption2.bold())
                                            .foregroundStyle(hit.speaker == "You" ? .blue : .purple)
                                        Text(highlighted(hit.text))
                                            .font(.callout)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .padding(12)
                            .cardStyle(cornerRadius: 10)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MCTheme.canvas)
        .task(id: query) {
            hits = TranscriptSearch.search(query)
        }
    }

    /// The matched word set in semibold — enough emphasis to scan, calm
    /// enough to read.
    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        if let range = attributed.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[range].font = .callout.weight(.semibold)
            attributed[range].foregroundColor = .blue
        }
        return attributed
    }
}
