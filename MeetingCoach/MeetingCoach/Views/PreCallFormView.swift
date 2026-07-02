import SwiftUI

/// Quick form for entering pre-call context before going live.
struct PreCallFormView: View {
    @Binding var context: PreCallContext
    let onStart: () -> Void
    @Environment(\.dismiss) private var dismiss

    private static let durationOptions = [15, 30, 60]

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
                    // Focus areas from recent history
                    FocusAreasBox()

                    // Meeting goal
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Meeting Goal").font(.caption.bold())
                        TextField("e.g. Close the deal, Get budget approval", text: $context.meetingGoal)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Meeting type — changes what good facilitation looks like
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Meeting Type").font(.caption.bold())
                        Picker("", selection: Binding(
                            get: { context.meetingType ?? .general },
                            set: { context.meetingType = $0 }
                        )) {
                            ForEach(MeetingType.allCases) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        Text("A 1:1 tolerates long updates; a sales call coaches you to listen and ask.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }

                    // Duration — dropdown
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scheduled Duration").font(.caption.bold())
                        Picker("", selection: $context.scheduledDurationMinutes) {
                            ForEach(Self.durationOptions, id: \.self) { min in
                                Text("\(min) min").tag(min)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Participants — always visible, persisted
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

                        if context.participants.isEmpty {
                            Text("Add people you're meeting with — they'll be remembered next time")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
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
                }
                .padding()
            }

            Divider()

            // Start button
            HStack {
                Spacer()
                Button {
                    ParticipantStore.save(context.participants)
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
        .onAppear {
            // Load remembered participants if none set yet
            if context.participants.isEmpty {
                context.participants = ParticipantStore.load()
            }
        }
    }
}

/// Shows focus areas from recent session history in the pre-call form.
private struct FocusAreasBox: View {
    @State private var areas: [String] = []

    var body: some View {
        if !areas.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Focus Areas", systemImage: "target")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                ForEach(areas, id: \.self) { area in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.orange)
                            .frame(width: 4, height: 4)
                        Text(area)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.2), lineWidth: 1))
        }
    }

    init() {
        let sessions = SessionTrends.loadAll()
        _areas = State(initialValue: SessionTrends.focusAreas(from: sessions))
    }
}

/// Persists participants across sessions.
enum ParticipantStore {
    private static let key = "savedParticipants"

    static func save(_ participants: [PreCallContext.Participant]) {
        // Only save non-empty entries
        let valid = participants.filter { !$0.name.isEmpty }
        guard let data = try? JSONEncoder().encode(valid) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> [PreCallContext.Participant] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let participants = try? JSONDecoder().decode([PreCallContext.Participant].self, from: data)
        else { return [] }
        return participants
    }
}
