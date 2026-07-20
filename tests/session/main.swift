import Foundation

// Session-lifecycle checks: drive the REAL LiveSessionViewModel through
// start → speech → stop using the same hooks live capture uses, and assert
// what the transcript pane renders (turns + livePartials) survives Stop.
//
// Born from a real regression (2026-07-20): hitting Stop blanked the
// transcript — partials were wiped without committing, and turns only
// rebuilt during live evaluation, so late words never reached the pane.

var fail = false
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("session \(label): \(ok ? "PASS" : "FAIL\(detail.isEmpty ? "" : " — \(detail)")")")
    if !ok { fail = true }
}

@MainActor
func runTests() async {
    // Session saves land in a scratch dir, never ~/Documents.
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("mc-session-tests-\(ProcessInfo.processInfo.processIdentifier)")
    UserDefaults.standard.set(scratch.path, forKey: "sessionFolderPath")
    defer {
        try? FileManager.default.removeItem(at: scratch)
        UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
    }

    // 1. The regression: speech still in the recognizers' pending line
    //    (nothing committed yet) must survive Stop — as committed
    //    utterances AND as visible turns. Before the fix the pane
    //    collapsed to its empty state the moment Stop was hit.
    do {
        let vm = LiveSessionViewModel()
        vm.startLive(context: PreCallContext())
        try? await Task.sleep(for: .milliseconds(300))   // let start settle
        guard let capture = AudioCaptureManager.last else {
            check(false, "capture manager wired"); return
        }
        capture.onPartialText?("You", "let's see if when I hit stop it")
        check(vm.livePartials["You"] != nil, "partial visible while live")

        vm.stopLive()
        check(vm.utterances.contains { $0.text.contains("when I hit stop") },
              "pending words committed on Stop", "utterances: \(vm.utterances.count)")
        check(!vm.turns.isEmpty, "pane still has turns after Stop (partial-only session)",
              "turns empty — the pane would blank")
        check(vm.hasSession, "hasSession still true (view doesn't switch away)")
        check(capture.stopped, "capture actually stopped")
    }

    // 2. Committed speech before the first 5s signal tick must also stay
    //    visible: per-utterance evaluation builds turns immediately, and
    //    Stop must not lose them (or the final pending tail on top).
    do {
        let vm = LiveSessionViewModel()
        vm.startLive(context: PreCallContext())
        try? await Task.sleep(for: .milliseconds(300))
        guard let capture = AudioCaptureManager.last else {
            check(false, "capture manager wired (2)"); return
        }
        capture.onUtterance?(Utterance(t: 1, speaker: "You",
            text: "Alright, we are talking again for the second test.", endT: 4))
        capture.onUtterance?(Utterance(t: 6, speaker: "Meeting",
            text: "Looks like they did fix it this time around.", endT: 9))
        capture.onPartialText?("You", "and this tail was still pending")
        try? await Task.sleep(for: .milliseconds(50))

        let turnsBefore = vm.turns.count
        check(turnsBefore > 0, "turns build per-utterance while live", "got \(turnsBefore)")

        vm.stopLive()
        let joined = vm.turns.map(\.text).joined(separator: " ")
        check(joined.contains("talking again") && joined.contains("did fix it"),
              "committed speech still in the pane after Stop")
        check(joined.contains("still pending"),
              "pending tail reaches the pane after Stop", "turns: \(joined.prefix(120))")
        check(vm.utterances.count == 3, "all words in the saved record", "got \(vm.utterances.count)")

        // The saved session file contains the tail too — stop must not
        // drop the last thing someone said.
        if let saved = try? FileManager.default.contentsOfDirectory(atPath: scratch.path),
           let file = saved.first(where: { $0.hasPrefix("session_") }),
           let body = try? String(contentsOfFile: scratch.appendingPathComponent(file).path,
                                  encoding: .utf8) {
            check(body.contains("still pending"), "saved session includes the pending tail")
        } else {
            check(false, "session file written to the scratch folder")
        }
    }

    // 3. Stopping an empty session (mic never heard anything) stays sane:
    //    no crash, no phantom turns, pane shows its empty state honestly.
    do {
        let vm = LiveSessionViewModel()
        vm.startLive(context: PreCallContext())
        try? await Task.sleep(for: .milliseconds(300))
        vm.stopLive()
        check(vm.turns.isEmpty && vm.utterances.isEmpty && !vm.hasSession,
              "empty session stops clean")
    }
}

await runTests()
exit(fail ? 1 : 0)
