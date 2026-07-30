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

    // 3. Speaker identity: system-channel diarization splits "Them" into
    //    Them 1/2, renaming survives later (stale-label) segment passes,
    //    and renames reach the capture manager (voice-profile path).
    do {
        let vm = LiveSessionViewModel()
        vm.startLive(context: PreCallContext())
        try? await Task.sleep(for: .milliseconds(300))
        guard let capture = AudioCaptureManager.last else {
            check(false, "capture manager wired (3)"); return
        }
        capture.onUtterance?(Utterance(t: 1, speaker: "You",
            text: "Welcome everyone, thanks for making the time today.", endT: 4))
        capture.onUtterance?(Utterance(t: 6, speaker: "Them",
            text: "Hello from the first remote person on the call.", endT: 9))
        capture.onUtterance?(Utterance(t: 12, speaker: "Them",
            text: "And hello from the second remote voice as well.", endT: 15))
        try? await Task.sleep(for: .milliseconds(50))

        capture.onSpeakerSegments?(.system, [
            SpeakerSegment(speaker: "Them 1", start: 5.8, end: 9.2),
            SpeakerSegment(speaker: "Them 2", start: 11.8, end: 15.2),
        ])
        try? await Task.sleep(for: .milliseconds(50))
        let labels = vm.utterances.map(\.speaker)
        check(labels == ["You", "Them 1", "Them 2"],
              "system channel splits Them into speakers", "got \(labels)")

        vm.renameSpeaker("Them 2", to: "William")
        check(vm.utterances.map(\.speaker) == ["You", "Them 1", "William"],
              "rename relabels the transcript",
              "got \(vm.utterances.map(\.speaker))")
        check(vm.turns.contains { $0.speaker == "William" },
              "rename rebuilds the visible turns")
        check(capture.renames.contains { $0 == ("Them 2", "William") },
              "rename routed to capture (voice profile path)")

        // A publish that raced the rename still says "Them 2" — it must
        // not revert William.
        capture.onSpeakerSegments?(.system, [
            SpeakerSegment(speaker: "Them 1", start: 5.8, end: 9.2),
            SpeakerSegment(speaker: "Them 2", start: 11.8, end: 15.4),
        ])
        try? await Task.sleep(for: .milliseconds(50))
        check(vm.utterances.map(\.speaker) == ["You", "Them 1", "William"],
              "stale segment labels don't revert a rename",
              "got \(vm.utterances.map(\.speaker))")

        // Renames still work from the post-session view.
        vm.stopLive()
        vm.renameSpeaker("Them 1", to: "Priya")
        check(vm.utterances.map(\.speaker) == ["You", "Priya", "William"],
              "rename works after Stop",
              "got \(vm.utterances.map(\.speaker))")
        vm.deleteSession()
    }

    // 4. Stopping an empty session (mic never heard anything) stays sane:
    //    no crash, no phantom turns, pane shows its empty state honestly.
    do {
        let vm = LiveSessionViewModel()
        vm.startLive(context: PreCallContext())
        try? await Task.sleep(for: .milliseconds(300))
        vm.stopLive()
        check(vm.turns.isEmpty && vm.utterances.isEmpty && !vm.hasSession,
              "empty session stops clean")
    }

    // 5. Saved transcripts coalesce fragments into turns (2026-07-29 field
    //    report): the far side commits in 1-3 word chunks, and a saved file
    //    of shredded lines is unreadable next to any other tool's export.
    //    Same-speaker fragments inside the join gap save as ONE line;
    //    speaker changes still split.
    do {
        let vm = LiveSessionViewModel()
        vm.startLive(context: PreCallContext())
        try? await Task.sleep(for: .milliseconds(300))
        guard let capture = AudioCaptureManager.last else {
            check(false, "capture manager wired (5)"); return
        }
        capture.onUtterance?(Utterance(t: 1, speaker: "Them", text: "Can you hear", endT: 2))
        capture.onUtterance?(Utterance(t: 2.4, speaker: "Them", text: "me?", endT: 2.8))
        capture.onUtterance?(Utterance(t: 4, speaker: "Them", text: "I went on", endT: 5))
        capture.onUtterance?(Utterance(t: 5.5, speaker: "Them", text: "Friday night.", endT: 6.5))
        capture.onUtterance?(Utterance(t: 8, speaker: "You", text: "Loud and clear.", endT: 9))
        try? await Task.sleep(for: .milliseconds(50))
        vm.stopLive()

        var body = ""
        if let saved = try? FileManager.default.contentsOfDirectory(atPath: scratch.path) {
            for file in saved where file.hasPrefix("session_") {
                let content = (try? String(
                    contentsOfFile: scratch.appendingPathComponent(file).path,
                    encoding: .utf8)) ?? ""
                if content.contains("Can you hear") { body = content }
            }
        }
        check(body.contains("- [00:01] Them: Can you hear me? I went on Friday night."),
              "far-side fragments save as one coalesced line",
              "transcript: \(body.components(separatedBy: "## Transcript").last?.prefix(200) ?? "")")
        check(!body.contains("Them: me?"),
              "no shredded fragment lines in the saved file")
        check(body.contains("- [00:08] You: Loud and clear."),
              "speaker change still starts a new line")
        vm.deleteSession()
    }
}

await runTests()
exit(fail ? 1 : 0)
