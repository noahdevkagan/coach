import SwiftUI

struct SimulationTimelineView: View {
    @Bindable var simulation: SimulationViewModel

    var body: some View {
        Group {
            if simulation.calls.isEmpty && !simulation.isRunning {
                emptyState
            } else {
                HSplitView {
                    // Left: coaching calls
                    callsPanel
                        .frame(minWidth: 280)

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

    // MARK: - Coaching calls panel

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

    // MARK: - Analysis panel (what the model is looking at)

    private var analysisPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                if simulation.isAnalyzing {
                    ProgressView().controlSize(.mini)
                }
                Text(simulation.isAnalyzing ? "Analyzing Window" : "Transcript Window")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatTime(simulation.currentTime))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if simulation.currentWindow.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("The transcript window being\nanalyzed will appear here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(simulation.currentWindow) { utt in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(utt.formattedTime)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 36, alignment: .trailing)
                                    Text(utt.speaker)
                                        .font(.caption2.bold())
                                        .foregroundStyle(utt.isYou ? .blue : .orange)
                                        .frame(width: 50, alignment: .leading)
                                        .lineLimit(1)
                                    Text(utt.text)
                                        .font(.caption)
                                        .foregroundStyle(.primary)
                                }
                                .id(utt.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: simulation.currentWindow.count) { _, _ in
                        if let last = simulation.currentWindow.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .background(simulation.isAnalyzing ? Color.blue.opacity(0.02) : .clear)
            }
        }
        .background(Color(.controlBackgroundColor).opacity(0.5))
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let mm = Int(t) / 60
        let ss = Int(t) % 60
        return String(format: "%02d:%02d", mm, ss)
    }
}

// MARK: - Call Card

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
