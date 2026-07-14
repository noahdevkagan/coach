import SwiftUI

struct SimulationTimelineView: View {
    @Bindable var simulation: SimulationViewModel

    var body: some View {
        Group {
            if simulation.calls.isEmpty && simulation.v2Nudges.isEmpty && !simulation.isRunning {
                emptyState
            } else {
                HSplitView {
                    // Left: coaching calls or v2 nudges
                    if simulation.isV2Mode {
                        nudgesPanel
                            .frame(minWidth: 280)
                    } else {
                        callsPanel
                            .frame(minWidth: 280)
                    }

                    // Right: what's being analyzed
                    analysisPanel
                        .frame(minWidth: 220, idealWidth: 280)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.textBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Load a transcript and run training")
                .foregroundStyle(.secondary)
            Text("Coaching calls will appear here as the meeting replays")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - V2 Nudges panel

    private var nudgesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Nudges (v2)")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if !simulation.v2Nudges.isEmpty {
                    Text("\(simulation.v2Nudges.count)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(simulation.v2Nudges) { nudge in
                            SimNudgeCardView(nudge: nudge)
                                .id(nudge.id)
                        }
                        if simulation.isRunning {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Scanning...").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .id("loading")
                        }
                    }
                    .padding()
                }
                .onChange(of: simulation.v2Nudges.count) { _, _ in
                    if let last = simulation.v2Nudges.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Coaching calls panel (legacy LLM)

    private var callsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Coaching Calls")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if !simulation.calls.isEmpty {
                    Text("\(simulation.calls.count)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(simulation.calls) { call in
                            CallCardView(call: call)
                                .id(call.id)
                        }
                        if simulation.isRunning && simulation.isAnalyzing {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Analyzing...").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .id("loading")
                        }
                    }
                    .padding()
                }
                .onChange(of: simulation.calls.count) { _, _ in
                    if let last = simulation.calls.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Analysis panel (full transcript, highlights current window)

    private var analysisPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                if simulation.isAnalyzing {
                    ProgressView().controlSize(.mini)
                }
                Text("Transcript")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if !simulation.utterances.isEmpty {
                    Text("\(simulation.utterances.count) utterances")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(formatTime(simulation.currentTime))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if simulation.utterances.isEmpty {
                transcriptEmptyState
            } else {
                transcriptScrollView
            }
        }
        .background(Color(.controlBackgroundColor).opacity(0.5))
    }

    private var transcriptEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("The full transcript will\nappear here")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcriptScrollView: some View {
        let windowIds = Set(simulation.currentWindow.map { $0.id })
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(simulation.utterances) { utt in
                        TranscriptRow(utterance: utt, highlighted: windowIds.contains(utt.id))
                            .id(utt.id)
                    }
                }
                .padding(10)
            }
            .onChange(of: simulation.currentTime) { _, _ in
                let win = simulation.currentWindow
                if let mid = win.dropFirst(win.count / 2).first {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(mid.id, anchor: .center)
                    }
                }
            }
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let mm = Int(t) / 60
        let ss = Int(t) % 60
        return String(format: "%02d:%02d", mm, ss)
    }
}

// MARK: - Sim Nudge Card (v2)

struct SimNudgeCardView: View {
    let nudge: Nudge

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(nudge.formattedTime)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            Circle()
                .fill(urgencyColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(nudge.text)
                    .font(.system(.body, weight: .semibold))

                HStack(spacing: 8) {
                    Text(nudge.type.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(urgencyColor.opacity(0.15))
                        .foregroundStyle(urgencyColor)
                        .clipShape(Capsule())

                    Text(nudge.urgency.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(10)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var urgencyColor: Color {
        if nudge.type.isPositive { return .green }
        switch nudge.urgency {
        case .low: return .gray
        case .med: return .blue
        case .high: return .orange
        }
    }
}

// MARK: - Call Card (legacy)

struct CallCardView: View {
    let call: CoachingCall

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Timestamp
            Text(call.formattedTime)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            // Signal indicator
            Circle()
                .fill(tierColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                // Nudge (the main coaching line)
                Text(call.nudge)
                    .font(.system(.body, weight: .semibold))

                HStack(spacing: 8) {
                    // Signal badge
                    Text(call.signalId.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tierColor.opacity(0.15))
                        .foregroundStyle(tierColor)
                        .clipShape(Capsule())

                    // Confidence
                    Text(String(format: "%.0f%%", call.confidence * 100))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    // Trigger type
                    Text(call.reason.rawValue.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Evidence
                if !call.evidence.isEmpty {
                    Text(call.evidence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }

            Spacer()
        }
        .padding(10)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var tierColor: Color {
        let tierA = ["no_decision_owner_date", "alignment_reached_still_talking",
                     "reopening_closed_thread", "buried_signal_ignored"]
        return tierA.contains(call.signalId) ? .blue : .orange
    }
}

// MARK: - Transcript Row

struct TranscriptRow: View {
    let utterance: Utterance
    let highlighted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(utterance.formattedTime)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(highlighted ? .secondary : .tertiary)
                .frame(width: 36, alignment: .trailing)
            Text(utterance.speaker)
                .font(.caption2.bold())
                .foregroundStyle(utterance.isYou ? .blue : .orange)
                .frame(width: 50, alignment: .leading)
                .lineLimit(1)
            Text(utterance.text)
                .font(.caption)
                .foregroundStyle(highlighted ? .primary : .secondary)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(highlighted ? Color.blue.opacity(0.08) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
