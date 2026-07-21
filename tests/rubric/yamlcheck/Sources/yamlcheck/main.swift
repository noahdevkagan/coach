import Foundation

// Rubric YAML checks against the app's real parser/serializer.
// Usage: yamlcheck <path-to-default-rubric.yaml>

var fail = false
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("\(label): \(ok ? "PASS" : "FAIL\(detail.isEmpty ? "" : " — \(detail)")")")
    if !ok { fail = true }
}

// 1. Every shipped default rubric (repo rubrics/default.yaml + the app's
//    bundled Resources/default_rubric.yaml) parses, is v2, and carries
//    EXACTLY the DefaultBuiltins.cut — the proof that the shipped files and
//    the canonical map in TuningTypes.swift never drift.
guard CommandLine.arguments.count > 1 else {
    print("usage: yamlcheck <default-rubric.yaml> [more-default-rubrics.yaml...]")
    exit(2)
}
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let label = url.lastPathComponent
    do {
        let rubric = try loadRubric(from: url)
        check(rubric.name == "default", "\(label): name", "got \(rubric.name)")
        check(rubric.version == 2, "\(label): version 2", "got \(rubric.version)")
        check(rubric.signals.count == 5, "\(label): signals", "got \(rubric.signals.count)")
        check(rubric.builtins == DefaultBuiltins.cut,
              "\(label): builtins == DefaultBuiltins.cut",
              "file has \(rubric.builtins.count) entries, map has \(DefaultBuiltins.cut.count)")
        let customs = rubric.customSemanticSignals.map(\.id)
        check(customs == ["reopening_closed_thread"], "\(label): custom signal derivation", "got \(customs)")
    } catch {
        check(false, "\(label): parses", error.localizedDescription)
    }
}

// 1b. The cut itself keeps exactly the intended few: talkTime tuned rarer,
//     everything else in the map disabled, keeps absent (= enabled stock).
do {
    let talk = DefaultBuiltins.cut["talkTime"]
    check(talk == SignalTuning(enabled: true, thresholdMultiplier: 1.5, cooldownMultiplier: 2.0),
          "cut: talkTime kept but rarer", "got \(String(describing: talk))")
    for keep in ["stackedQuestions", "nextSteps", "commitmentLocked", "hedgeNotPinned"] {
        check(DefaultBuiltins.cut[keep] == nil, "cut: \(keep) absent (enabled stock)")
    }
    let disabled = DefaultBuiltins.cut.filter { !$0.value.enabled }
    check(disabled.count == 19, "cut: 19 signals disabled", "got \(disabled.count)")
}

// 2. builtins parse: enabled/multipliers read; missing keys default neutral.
let tunedYAML = """
version: 1
name: tuned
builtins:
  talkTime: { enabled: false }
  voiceShare: { threshold_multiplier: 1.5, cooldown_multiplier: 2 }
signals:
  - id: rambling_intro
    tier: B
    description: The user takes more than a minute to get to the point.
    nudge: "Get to the point"
"""
do {
    let rubric = try parseRubric(tunedYAML)
    let talk = rubric.builtins["talkTime"]
    let voice = rubric.builtins["voiceShare"]
    check(talk?.enabled == false && talk?.thresholdMultiplier == 1.0,
          "builtins enabled parse", "got \(String(describing: talk))")
    check(voice?.enabled == true && voice?.thresholdMultiplier == 1.5 && voice?.cooldownMultiplier == 2.0,
          "builtins multiplier parse (int + double)", "got \(String(describing: voice))")
    check(rubric.customSemanticSignals.map(\.id) == ["rambling_intro"],
          "custom signal from tuned rubric")
    check(rubric.customSemanticSignals.first?.name == "Rambling Intro",
          "custom display name", "got \(rubric.customSemanticSignals.first?.name ?? "nil")")
} catch {
    check(false, "tuned rubric parses", error.localizedDescription)
}

// 3. Round-trip: toYAML output re-parses to the same tuning and signals,
//    including quoting-hostile text.
do {
    let original = try parseRubric(tunedYAML)
    var mutated = original
    mutated.cadence.heartbeatSeconds = 30
    let hostile = Rubric(
        name: "hostile: \"name\"",
        version: 2,
        cadence: mutated.cadence,
        window: original.window,
        output: original.output,
        signals: [Signal(id: "check_colons", tier: "B",
                         description: "Watch for: quotes \"inside\", colons: and\nnewlines.",
                         nudge: "Say it plainly: now", needsDiarization: true, minConfidence: 0.8)],
        builtins: original.builtins)
    let reparsed = try parseRubric(hostile.toYAML())
    check(reparsed.name == hostile.name, "round-trip name", "got \(reparsed.name)")
    check(reparsed.cadence.heartbeatSeconds == 30, "round-trip cadence")
    check(reparsed.builtins["talkTime"]?.enabled == false
          && reparsed.builtins["voiceShare"]?.thresholdMultiplier == 1.5,
          "round-trip builtins")
    let sig = reparsed.signal(byId: "check_colons")
    check(sig != nil && sig!.needsDiarization && sig!.nudge == "Say it plainly: now",
          "round-trip hostile signal", "got \(String(describing: sig))")
} catch {
    check(false, "round-trip", error.localizedDescription)
}

// 4. Neutral builtins are omitted from serialized output.
let clean = Rubric(name: "clean", version: 1,
                   cadence: Cadence(), window: TranscriptWindow(),
                   output: OutputConfig(), signals: [],
                   builtins: ["talkTime": SignalTuning()])
check(!clean.toYAML().contains("builtins:"), "neutral builtins omitted")

// 5. v2 migration: an untouched v1 file gains the cut, keeps every field
//    the parser drops (params, end_of_meeting, comments), backs up first,
//    and is a no-op the second time. A user-tuned file is never touched.
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("yamlcheck-migrate-\(ProcessInfo.processInfo.processIdentifier)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let v1YAML = """
    # user comment that must survive
    version: 1
    name: default
    signals:
      - id: no_decision_owner_date
        tier: A
        description: A clear question has been open too long.
        params: { open_minutes_threshold: 10 }
        nudge: "Decide it or park it."
    end_of_meeting:
      - id: decision_playback
        description: A playback of every decision.
    """
    let v1URL = dir.appendingPathComponent("v1.yaml")
    try v1YAML.write(to: v1URL, atomically: true, encoding: .utf8)

    var backups: [String] = []
    let migrated = Rubric.migrateToV2(at: v1URL) { backups.append($0) }
    let after = try String(contentsOf: v1URL, encoding: .utf8)
    let reparsed = try loadRubric(from: v1URL)
    check(migrated, "migration: v1 file rewritten")
    check(backups == ["pre-v2-cut"], "migration: backup requested first", "got \(backups)")
    check(reparsed.version == 2, "migration: version bumped", "got \(reparsed.version)")
    check(reparsed.builtins == DefaultBuiltins.cut, "migration: cut applied")
    check(after.contains("# user comment that must survive")
          && after.contains("params: { open_minutes_threshold: 10 }")
          && after.contains("end_of_meeting:"),
          "migration: comments/params/end_of_meeting survive")
    check(!Rubric.migrateToV2(at: v1URL), "migration: second run is a no-op")

    // User-tuned v1 rubric: builtins present -> preserved verbatim.
    let tunedURL = dir.appendingPathComponent("tuned.yaml")
    let tunedText = """
    version: 1
    name: default
    builtins:
      interruption: { enabled: true, threshold_multiplier: 0.8, cooldown_multiplier: 1.0 }
    """
    try tunedText.write(to: tunedURL, atomically: true, encoding: .utf8)
    check(!Rubric.migrateToV2(at: tunedURL), "migration: user-tuned builtins never touched")
    check(try String(contentsOf: tunedURL, encoding: .utf8) == tunedText,
          "migration: user-tuned file byte-identical")
} catch {
    check(false, "migration checks", error.localizedDescription)
}

exit(fail ? 1 : 0)
