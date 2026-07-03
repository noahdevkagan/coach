import SwiftUI

/// Quick form for entering pre-call context before going live.
struct PreCallFormView: View {
    @Binding var context: PreCallContext
    let onStart: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// People from past meetings, offered as one-tap suggestions rather than
    /// pre-filled — most meetings only involve a few of them.
    @State private var remembered: [PreCallContext.Participant] = []

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
                    // Meeting goal
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Meeting Goal").font(.caption.bold())
                        TextField("e.g. Close the deal, Get budget approval", text: $context.meetingGoal)
                            .textFieldStyle(.roundedBorder)
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

                        if context.participants.isEmpty && remembered.isEmpty {
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

                        // Remembered people as one-tap chips, not pre-filled rows
                        let suggestions = remembered.filter { person in
                            !context.participants.contains {
                                $0.name.caseInsensitiveCompare(person.name) == .orderedSame
                            }
                        }
                        if !suggestions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    Text("Recent:")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    ForEach(suggestions) { person in
                                        Button {
                                            context.participants.append(
                                                .init(name: person.name, role: person.role)
                                            )
                                        } label: {
                                            Text(person.role.isEmpty
                                                 ? person.name
                                                 : "\(person.name) · \(person.role)")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
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
        .frame(width: 480, height: 420)
        .onAppear {
            remembered = ParticipantStore.load()
        }
    }
}

/// Persists participants across sessions.
enum ParticipantStore {
    private static let key = "savedParticipants"

    static func save(_ participants: [PreCallContext.Participant]) {
        // Merge this meeting's people into the remembered list (dedupe by
        // name) — the form only contains today's participants, not everyone.
        let valid = participants.filter { !$0.name.isEmpty }
        var merged = load()
        for person in valid {
            if let i = merged.firstIndex(where: {
                $0.name.caseInsensitiveCompare(person.name) == .orderedSame
            }) {
                merged[i].role = person.role
            } else {
                merged.append(person)
            }
        }
        guard let data = try? JSONEncoder().encode(merged) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> [PreCallContext.Participant] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let participants = try? JSONDecoder().decode([PreCallContext.Participant].self, from: data)
        else { return [] }
        return participants
    }
}
