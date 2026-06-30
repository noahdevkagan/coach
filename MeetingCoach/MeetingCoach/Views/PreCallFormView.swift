import SwiftUI

/// Quick form for entering pre-call context before going live.
struct PreCallFormView: View {
    @Binding var context: PreCallContext
    let onStart: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Pre-Call Setup").font(.title2.bold())
                    Text("Set your goal so the coach knows what to watch for")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Meeting goal
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Meeting Goal").font(.caption.bold())
                        TextField("e.g. Close the deal, Get budget approval", text: $context.meetingGoal)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Duration
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scheduled Duration").font(.caption.bold())
                        HStack {
                            Stepper("\(context.scheduledDurationMinutes) min",
                                    value: $context.scheduledDurationMinutes,
                                    in: 5...120, step: 5)
                        }
                    }

                    // Participants
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Participants").font(.caption.bold())
                            Spacer()
                            Button {
                                context.participants.append(.init())
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        }

                        ForEach($context.participants) { $participant in
                            HStack(spacing: 8) {
                                TextField("Name", text: $participant.name)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Role", text: $participant.role)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 120)
                                Button {
                                    context.participants.removeAll { $0.id == participant.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Known tendencies
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("My Known Tendencies").font(.caption.bold())
                            Spacer()
                            Button {
                                context.myKnownTendencies.append("")
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        }

                        ForEach(Array(context.myKnownTendencies.enumerated()), id: \.offset) { i, _ in
                            HStack {
                                TextField("e.g. Talk too much, avoid pricing", text: $context.myKnownTendencies[i])
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    context.myKnownTendencies.remove(at: i)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Start button
            HStack {
                Spacer()
                Button {
                    dismiss()
                    onStart()
                } label: {
                    Label("Start Session", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480, height: 520)
    }
}
