import Foundation

// Rubric YAML checks against the app's real parser/serializer.
// Usage: yamlcheck <path-to-default-rubric.yaml>

var fail = false
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("\(label): \(ok ? "PASS" : "FAIL\(detail.isEmpty ? "" : " — \(detail)")")")
    if !ok { fail = true }
}

// 1. The shipped default rubric parses, and its only non-builtin signal id
//    becomes a custom semantic signal.
guard CommandLine.arguments.count > 1 else {
    print("usage: yamlcheck <default-rubric.yaml>")
    exit(2)
}
let defaultURL = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    let rubric = try loadRubric(from: defaultURL)
    check(rubric.name == "default", "default rubric name", "got \(rubric.name)")
    check(rubric.signals.count == 5, "default rubric signals", "got \(rubric.signals.count)")
    check(rubric.builtins.isEmpty, "default rubric has no builtins section")
    let customs = rubric.customSemanticSignals.map(\.id)
    check(customs == ["reopening_closed_thread"], "custom signal derivation", "got \(customs)")
} catch {
    check(false, "default rubric parses", error.localizedDescription)
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

exit(fail ? 1 : 0)
