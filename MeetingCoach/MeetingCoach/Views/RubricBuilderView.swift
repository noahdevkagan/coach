import SwiftUI

/// The rubric builder sheet: describe the coaching you want in plain English
/// and let the local model rewrite the rubric — then review every change as
/// toggles and levels before it becomes the active coaching style. Fully
/// usable without a model: the same rows edit manually.
struct RubricBuilderView: View {
    @Bindable var settings: SettingsViewModel
    @Bindable var ollamaManager: OllamaManager
    @Environment(\.dismiss) private var dismiss
    @State private var vm = RubricBuilderViewModel()

    private var hasModel: Bool {
        !settings.availableModels.isEmpty && !settings.useMock
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    describeSection
                    builtinSection("Instant nudges", rows: RubricBuilderViewModel.instantTypes)
                    builtinSection("AI nudges", rows: RubricBuilderViewModel.aiTypes)
                    builtinSection("Green nudges (reinforcement)", rows: RubricBuilderViewModel.greenTypes)
                    customSection
                }
                .padding()
            }

            Divider()
            footer
        }
        .frame(width: 620, height: 680)
        .onAppear {
            vm.load(from: (try? settings.loadRubricOrDefault()) ?? .builtInDefault)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Coaching Style").font(.title2.bold())
                Text("What the coach watches for, and how eagerly")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Rubric name", text: $vm.rubricName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
        }
        .padding()
    }

    private var describeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Describe it in your own words", systemImage: "wand.and.stars")
                .font(.headline)
            Text(hasModel
                 ? "e.g. \"Coach me to stop rambling and always lock next steps. I don't care about time warnings.\""
                 : "Install a local model in Settings to generate a rubric from a description — the toggles below always work.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $vm.request)
                .font(.body)
                .frame(minHeight: 54, maxHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
                .disabled(!hasModel)

            HStack {
                Button {
                    vm.generate(settings: settings, ollamaManager: ollamaManager)
                } label: {
                    if vm.isGenerating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Rewriting rubric…")
                        }
                    } else {
                        Label("Generate", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasModel || vm.isGenerating
                          || vm.request.trimmingCharacters(in: .whitespaces).isEmpty)

                if let error = vm.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Spacer()
            }
        }
    }

    private func builtinSection(_ title: String, rows: [(NudgeType, String)]) -> some View {
        let types = Set(rows.map(\.0))
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach($vm.builtinRows) { $row in
                if types.contains(row.type) {
                    HStack(spacing: 10) {
                        Toggle(isOn: $row.enabled) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.type.displayName).font(.callout)
                                Text(row.blurb).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        Spacer()
                        Picker("", selection: $row.level) {
                            ForEach(RubricBuilderViewModel.BuiltinRow.Level.allCases) { level in
                                Text(level.rawValue).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 170)
                        .disabled(!row.enabled)
                        .help("How eagerly this signal fires")
                    }
                }
            }
        }
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Custom signals").font(.headline)
                Spacer()
                Button {
                    vm.customRows.append(.init(
                        signalId: "my_signal",
                        description: "",
                        nudge: ""))
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .font(.caption)
            }
            Text("Watched live by the local AI (needs a model + AI nudges on). Describe exactly what to look for.")
                .font(.caption).foregroundStyle(.secondary)

            ForEach($vm.customRows) { $row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("signal_id", text: $row.signalId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 180)
                        Spacer()
                        Button {
                            vm.customRows.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                    TextField("What should the coach look for?", text: $row.description, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                    TextField("Nudge shown mid-meeting (max 8 words)", text: $row.nudge)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(10)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if vm.customRows.isEmpty {
                Text("None yet — describe one above and Generate, or add one manually.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if vm.saved {
                Label("Saved — next session uses this style", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button("Cancel") { dismiss() }
            Button {
                vm.save(settings: settings)
            } label: {
                Label("Save as coaching style", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }
}
