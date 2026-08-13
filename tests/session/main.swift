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
            check(body.contains("**Language:** en"),
                  "saved session persists resolved ISO language")
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

    // 6. "Fix a misheard term" (transcript right-click): persists into the
    //    custom vocabulary, rewrites the current transcript in place, and
    //    hands the capture manager an updated normalizer for the rest of
    //    the call.
    do {
        UserDefaults.standard.removeObject(forKey: "customVocabularyText")
        let vm = LiveSessionViewModel()
        vm.startLive(context: PreCallContext())
        try? await Task.sleep(for: .milliseconds(300))
        guard let capture = AudioCaptureManager.last else {
            check(false, "capture manager wired (6)"); return
        }
        capture.onUtterance?(Utterance(t: 1, speaker: "Them",
            text: "We can sync on rock furred tomorrow.", endT: 3))
        try? await Task.sleep(for: .milliseconds(50))

        vm.fixMisheardTerm(wrote: "rock furred", canonical: "Rockford")
        check(vm.utterances.first?.text == "We can sync on Rockford tomorrow.",
              "fix rewrites the committed transcript in place",
              "got \(vm.utterances.first?.text ?? "nil")")
        check(vm.turns.first?.text.contains("Rockford") == true,
              "fix reaches the visible turns")
        let stored = UserDefaults.standard.string(forKey: "customVocabularyText") ?? ""
        check(stored.contains("Rockford = rock furred"),
              "fix persists into the custom vocabulary", "stored: \(stored)")
        check(capture.vocabulary?.normalize("more rock furred talk")
              == "more Rockford talk",
              "running capture gets the updated normalizer")
        vm.stopLive()
        vm.deleteSession()
        UserDefaults.standard.removeObject(forKey: "customVocabularyText")
    }

    // 7. One-on-one alias (display layer): renaming the sole diarized
    //    remote voice makes later RAW "Them" speech display — and save —
    //    under the same name, while stored labels stay raw so the alias
    //    can be dropped without provenance tracking.
    do {
        let vm = LiveSessionViewModel()
        vm.startLive(context: PreCallContext())
        try? await Task.sleep(for: .milliseconds(300))
        guard let capture = AudioCaptureManager.last else {
            check(false, "capture manager wired (7)"); return
        }
        capture.onUtterance?(Utterance(t: 1, speaker: "Them",
            text: "Hi there, can you hear me alright today?", endT: 3))
        try? await Task.sleep(for: .milliseconds(50))
        capture.onSpeakerSegments?(.system, [
            SpeakerSegment(speaker: "Them 1", start: 0.9, end: 3.1),
        ])
        try? await Task.sleep(for: .milliseconds(50))

        vm.renameSpeaker("Them 1", to: "Lyndsay")
        check(vm.displaySpeaker("Them") == "Lyndsay",
              "sole remote name aliases raw Them",
              "got \(vm.displaySpeaker("Them"))")

        // Later far-side words the diarizer hasn't refined yet.
        capture.onUtterance?(Utterance(t: 5, speaker: "Them",
            text: "Great, let us get going then.", endT: 7))
        try? await Task.sleep(for: .milliseconds(50))
        check(vm.utterances.last?.speaker == "Them",
              "stored label stays raw (display-layer alias only)",
              "got \(vm.utterances.last?.speaker ?? "nil")")

        // Real-session regression (2026-08-13): LS-EEND briefly emitted a
        // second remote slot that never owned any transcript words. That
        // disabled the 1:1 alias, so a short unaligned "Yeah." rendered as
        // Them between correctly named Chad turns.
        capture.onSpeakerSegments?(.system, [
            SpeakerSegment(speaker: "Lyndsay", start: 0.9, end: 3.1),
            SpeakerSegment(speaker: "Them 2", start: 8.0, end: 8.2),
        ])
        try? await Task.sleep(for: .milliseconds(50))
        capture.onUtterance?(Utterance(t: 9, speaker: "Them",
            text: "Yeah.", endT: 9.2))
        try? await Task.sleep(for: .milliseconds(50))
        check(vm.displaySpeaker("Them") == "Lyndsay",
              "audio-only phantom slot does not disable one-on-one alias",
              "got \(vm.displaySpeaker("Them"))")

        vm.stopLive()
        var body = ""
        if let saved = try? FileManager.default.contentsOfDirectory(atPath: scratch.path) {
            for file in saved where file.hasPrefix("session_") {
                let content = (try? String(
                    contentsOfFile: scratch.appendingPathComponent(file).path,
                    encoding: .utf8)) ?? ""
                if content.contains("hear me alright") { body = content }
            }
        }
        check(body.contains("Lyndsay: Hi there, can you hear me alright today? Great, let us get going then. Yeah."),
              "saved file coalesces Them/Them-1 fragments under the real name",
              "transcript: \(body.components(separatedBy: "## Transcript").last?.prefix(200) ?? "")")
        check(!body.contains("] Them:") && !body.contains("] Them 1:"),
              "no raw Them lines survive in the saved file")
        vm.deleteSession()
    }

    // 8. A second remote voice retires the alias: raw "Them" reverts to
    //    numbered/raw labels instantly, while the explicitly named
    //    speaker's turns stay named.
    do {
        let vm = LiveSessionViewModel()
        vm.startLive(context: PreCallContext())
        try? await Task.sleep(for: .milliseconds(300))
        guard let capture = AudioCaptureManager.last else {
            check(false, "capture manager wired (8)"); return
        }
        capture.onUtterance?(Utterance(t: 1, speaker: "Them",
            text: "First remote voice speaking here now.", endT: 3))
        try? await Task.sleep(for: .milliseconds(50))
        capture.onSpeakerSegments?(.system, [
            SpeakerSegment(speaker: "Them 1", start: 0.9, end: 3.1),
        ])
        try? await Task.sleep(for: .milliseconds(50))
        vm.renameSpeaker("Them 1", to: "Lyndsay")

        capture.onUtterance?(Utterance(t: 5, speaker: "Them",
            text: "And a totally different second voice.", endT: 7))
        try? await Task.sleep(for: .milliseconds(50))
        check(vm.displaySpeaker("Them") == "Lyndsay", "alias active before second voice")

        // Diarizer now separates two people (stale "Them 1" label rides in).
        capture.onSpeakerSegments?(.system, [
            SpeakerSegment(speaker: "Them 1", start: 0.9, end: 3.1),
            SpeakerSegment(speaker: "Them 2", start: 4.9, end: 7.1),
        ])
        try? await Task.sleep(for: .milliseconds(50))
        check(vm.displaySpeaker("Them") == "Them",
              "second remote voice retires the alias")
        check(vm.utterances.map(\.speaker) == ["Lyndsay", "Them 2"],
              "named speaker keeps her turns; second voice gets its own label",
              "got \(vm.utterances.map(\.speaker))")

        // Chained rename stays stable alongside the alias machinery.
        vm.renameSpeaker("Lyndsay", to: "Lyndsay K")
        check(vm.utterances.map(\.speaker) == ["Lyndsay K", "Them 2"],
              "chained rename relabels cleanly",
              "got \(vm.utterances.map(\.speaker))")
        vm.stopLive()
        vm.deleteSession()
    }

    // 9. Pre-call seeding: exactly one named participant provisionally
    //    names the far side; an enrolled real name beats the guess; and
    //    multiple voices appearing revert to honest numbered labels.
    do {
        var ctx = PreCallContext()
        ctx.participants = [.init(name: "Priya", role: "designer")]
        let vm = LiveSessionViewModel()
        vm.startLive(context: ctx)
        try? await Task.sleep(for: .milliseconds(300))
        guard let capture = AudioCaptureManager.last else {
            check(false, "capture manager wired (9)"); return
        }
        check(vm.displaySpeaker("Them") == "Priya",
              "single pre-call participant seeds the provisional alias")
        check(vm.displaySpeaker("You") == "You", "alias never touches You")

        // A diarized voice carrying a real (enrolled) name outranks the seed.
        capture.onSpeakerSegments?(.system, [
            SpeakerSegment(speaker: "Caitlin", start: 1, end: 4),
        ])
        try? await Task.sleep(for: .milliseconds(50))
        check(vm.displaySpeaker("Them") == "Caitlin",
              "enrolled real name beats the pre-call seed",
              "got \(vm.displaySpeaker("Them"))")

        // Two distinct voices → never guess.
        capture.onSpeakerSegments?(.system, [
            SpeakerSegment(speaker: "Them 1", start: 1, end: 4),
            SpeakerSegment(speaker: "Them 2", start: 5, end: 8),
        ])
        try? await Task.sleep(for: .milliseconds(50))
        check(vm.displaySpeaker("Them") == "Them",
              "multiple voices revert to numbered labels")

        // Attribution lag: one ASR utterance spans both remote voices and
        // lands wholly on Them 1, so transcript evidence sees one label —
        // the diarizer's two-voice count must still veto the pre-call guess.
        capture.onUtterance?(Utterance(t: 1, speaker: "Them",
            text: "Long stretch of far side speech spanning both people.", endT: 9))
        try? await Task.sleep(for: .milliseconds(50))
        capture.onSpeakerSegments?(.system, [
            SpeakerSegment(speaker: "Them 1", start: 1.0, end: 8.2),
            SpeakerSegment(speaker: "Them 2", start: 8.3, end: 8.9),
        ])
        try? await Task.sleep(for: .milliseconds(50))
        check(vm.displaySpeaker("Them") == "Them",
              "group call with lagging attribution never shows the pre-call guess",
              "got \(vm.displaySpeaker("Them"))")
        vm.stopLive()
        vm.deleteSession()
    }

    // 10. Renaming after Stop rewrites ONLY the saved file's transcript
    //     section — title and review survive byte-for-byte.
    do {
        let vm = LiveSessionViewModel()
        vm.startLive(context: PreCallContext())
        try? await Task.sleep(for: .milliseconds(300))
        guard let capture = AudioCaptureManager.last else {
            check(false, "capture manager wired (10)"); return
        }
        capture.onUtterance?(Utterance(t: 1, speaker: "You",
            text: "Kicking off the design review now.", endT: 3))
        capture.onUtterance?(Utterance(t: 5, speaker: "Them",
            text: "Thanks, sharing my screen in a second.", endT: 7))
        try? await Task.sleep(for: .milliseconds(50))
        capture.onSpeakerSegments?(.system, [
            SpeakerSegment(speaker: "Them 1", start: 4.9, end: 7.1),
        ])
        try? await Task.sleep(for: .milliseconds(50))
        vm.stopLive()

        guard let path = vm.savedPath else {
            check(false, "session file saved (10)"); return
        }
        let url = URL(fileURLWithPath: path)
        // What the app would have added by now: a human title + a review.
        TranscriptSearch.setTitle("Design review · Priya", for: url)
        var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        content += "\n\n## Review\n\n- Notable: they drove the demo\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)

        vm.renameSpeaker("Them 1", to: "Priya")
        let after = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(after.contains("Priya: Thanks, sharing my screen"),
              "post-stop rename lands in the saved transcript",
              "file: \(after.prefix(300))")
        check(!after.contains("] Them 1:"), "old label gone from the saved transcript")
        check(after.contains("**Title:** Design review · Priya"),
              "title survives the transcript rewrite")
        check(after.contains("## Review") && after.contains("they drove the demo"),
              "review survives the transcript rewrite")
        vm.deleteSession()
    }

    // 11. Participant memory: renames persist names immediately (no voice
    //     profile needed), case-insensitively deduped, roles preserved;
    //     typeahead ranks prefix matches before substring matches.
    do {
        UserDefaults.standard.removeObject(forKey: "savedParticipants")
        ParticipantStore.save([.init(name: "Lyndsay", role: "founder")])
        ParticipantStore.remember(name: "  lyndsay ")
        var people = ParticipantStore.load()
        check(people.count == 1, "remember dedupes case-insensitively",
              "got \(people.map(\.name))")
        check(people.first?.role == "founder", "existing role preserved")

        ParticipantStore.remember(name: "Matt")
        people = ParticipantStore.load()
        check(people.map(\.name) == ["Lyndsay", "Matt"], "new name appended",
              "got \(people.map(\.name))")

        // A real rename reaches the store the moment it happens.
        let vm = LiveSessionViewModel()
        vm.startLive(context: PreCallContext())
        try? await Task.sleep(for: .milliseconds(300))
        AudioCaptureManager.last?.onUtterance?(Utterance(
            t: 1, speaker: "Them", text: "Hello over there.", endT: 2))
        try? await Task.sleep(for: .milliseconds(50))
        vm.renameSpeaker("Them", to: "Caitlin")
        check(ParticipantStore.load().contains { $0.name == "Caitlin" },
              "rename persists the name into participant memory immediately")
        vm.stopLive()
        vm.deleteSession()

        let ranked = ParticipantStore.typeaheadMatches(
            "ly", in: ["Molly", "Lyndsay", "Waly", "Lyle"])
        check(ranked == ["Lyndsay", "Lyle", "Molly", "Waly"],
              "typeahead ranks prefix before substring, stable within groups",
              "got \(ranked)")
        check(ParticipantStore.typeaheadMatches("", in: ["A", "B", "C", "D", "E", "F"])
              == ["A", "B", "C", "D", "E"],
              "empty query offers the first five candidates")
        check(ParticipantStore.typeaheadMatches("zz", in: ["Molly"]).isEmpty,
              "no match, no suggestions")
        UserDefaults.standard.removeObject(forKey: "savedParticipants")
    }

    // 12. PendingProfileSaves: naming before 3s of clip loses nothing —
    //     the save fires once the clip is viable, and session end refreshes
    //     only when the clip actually grew.
    do {
        var p = PendingProfileSaves()
        p.name(slot: 0, as: "Caitlin")
        check(p.due(clipSeconds: [0: 1.2], minSeconds: 3, final: false).isEmpty,
              "no save before the clip is viable")
        let first = p.due(clipSeconds: [0: 3.4], minSeconds: 3, final: false)
        check(first.map(\.name) == ["Caitlin"], "first viable save fires",
              "got \(first)")
        check(p.due(clipSeconds: [0: 3.4], minSeconds: 3, final: false).isEmpty,
              "no rewrite on every publish")
        check(p.due(clipSeconds: [0: 6.0], minSeconds: 3, final: false).isEmpty,
              "mid-session growth alone doesn't rewrite")
        check(p.due(clipSeconds: [0: 11.8], minSeconds: 3, final: true).map(\.name) == ["Caitlin"],
              "session end refreshes with the fuller clip")
        check(p.due(clipSeconds: [0: 11.8], minSeconds: 3, final: true).isEmpty,
              "final refresh is a no-op unless the clip grew")
        p.name(slot: 0, as: "Kate")
        check(p.due(clipSeconds: [0: 11.8], minSeconds: 3, final: true).map(\.name) == ["Kate"],
              "renaming owes a save under the new name")
        // A slot never named never saves, however long its clip.
        check(p.due(clipSeconds: [1: 12.0], minSeconds: 3, final: true).isEmpty,
              "unnamed slots (enrolled profiles) are never auto-refreshed")
    }
    // ---- Session model lifecycle -------------------------------------
    //
    // One coherent lifecycle per meeting: preparing -> (deterministic |
    // pinned). Activation runs after capture is up, refreshes the installed
    // list, reads free memory, preloads, and only then pins. Every await is
    // a place Stop or a replacing session can land, so these drive the races
    // directly rather than asserting the stored value alone.

    let gb = 1_073_741_824.0
    func installed(_ name: String, _ sizeGB: Double) -> OllamaModel {
        OllamaModel(name: name, size: Int64(sizeGB * gb), parameterSize: "")
    }
    /// Restore production seams between cases.
    func resetSeams() {
        LiveSessionViewModel.availableMemoryGB = { ModelMemory.availableGB }
        LiveSessionViewModel.preloadModel = { _ in nil }
        LiveSessionViewModel.unloadModel = { _ in }
        LiveSessionViewModel.completeReview = { _, _, _ in "" }
    }
    /// A settings stub wired for the real (non-mock) path.
    func liveSettings(_ model: String = "qwen3.5:4b") -> SettingsViewModel {
        let s = SettingsViewModel()
        s.useMock = false
        s.semanticCoachEnabled = true
        s.hasCheckedModels = true
        s.selectedModel = model
        s.availableModels = [installed("qwen3.5:9b", 6.6), installed("qwen3.5:4b", 3.4)]
        return s
    }

    // Policy, injected at exact pressures — no dependence on this machine.
    do {
        let pool = [installed("qwen3.5:9b", 6.6), installed("qwen3.5:4b", 3.4),
                    installed("granite4:3b", 2.1)]
        // The originating incident: 32 GB Mac, ~8 GB actually free. 9b passes
        // every static check (minRAMGB 16 on 32 GB) and still swaps.
        check(ModelMemory.modelForCurrentMemory(chosen: "qwen3.5:9b",
                                                installed: pool, availableGB: 8) == "qwen3.5:4b",
              "busy 32GB selects 4B instead of 9B",
              "got: \(ModelMemory.modelForCurrentMemory(chosen: "qwen3.5:9b", installed: pool, availableGB: 8) ?? "nil")")
        check(ModelMemory.modelForCurrentMemory(chosen: "qwen3.5:9b",
                                                installed: pool, availableGB: 24) == "qwen3.5:9b",
              "idle 32GB keeps 9B")
        check(ModelMemory.modelForCurrentMemory(chosen: "qwen3.5:9b",
                                                installed: pool, availableGB: 3) == nil,
              "nothing fits -> no model")
        check(ModelMemory.modelForCurrentMemory(chosen: "ghost:model",
                                                installed: pool, availableGB: 24) == "qwen3.5:9b",
              "a missing model is unsafe and steps down")
        check(ModelMemory.modelForCurrentMemory(chosen: "mystery:model",
                                                installed: [installed("mystery:model", 0)],
                                                availableGB: 64) == nil,
              "unknown size is unsafe, not assumed small")
    }

    // Happy path: refresh -> preload -> pin, in that order, and the SAME
    // model reaches preload, the pin, and the unload.
    do {
        resetSeams()
        var preloaded: [String] = []
        var unloaded: [String] = []
        LiveSessionViewModel.availableMemoryGB = { 24 }
        LiveSessionViewModel.preloadModel = { preloaded.append($0); return nil }
        LiveSessionViewModel.unloadModel = { unloaded.append($0) }

        let vm = LiveSessionViewModel()
        let settings = liveSettings("qwen3.5:9b")
        let manager = OllamaManager()
        vm.startLive(context: PreCallContext(), settings: settings, ollamaManager: manager)
        try? await Task.sleep(for: .milliseconds(500))

        check(vm.sessionModelState?.pinnedModel == "qwen3.5:9b",
              "activation pins the preloaded model",
              "state: \(String(describing: vm.sessionModelState))")
        check(settings.callLog.contains("refresh"),
              "installed list is refreshed before selection", "log: \(settings.callLog)")
        check(preloaded == ["qwen3.5:9b"],
              "exactly the selected model is preloaded", "preloaded: \(preloaded)")

        capture: do {
            guard let cap = AudioCaptureManager.last else { break capture }
            cap.onUtterance?(Utterance(t: 1, speaker: "You", text: "Some words here.", endT: 3))
        }
        vm.stopLive()
        try? await Task.sleep(for: .milliseconds(500))
        check(unloaded == ["qwen3.5:9b"],
              "warm-up, heartbeat, recap and unload all receive the same model",
              "preloaded: \(preloaded), unloaded: \(unloaded)")
        vm.deleteSession()
    }

    // Preload failure cannot produce a heartbeat.
    do {
        resetSeams()
        LiveSessionViewModel.availableMemoryGB = { 24 }
        LiveSessionViewModel.preloadModel = { _ in "out of memory" }
        let vm = LiveSessionViewModel()
        let settings = liveSettings()
        let manager = OllamaManager()
        vm.startLive(context: PreCallContext(), settings: settings, ollamaManager: manager)
        try? await Task.sleep(for: .milliseconds(500))
        check(vm.sessionModelState == .deterministic(vm.sessionModelState!.sessionID),
              "preload failure settles deterministic",
              "state: \(String(describing: vm.sessionModelState))")
        check(vm.sessionModelState?.pinnedModel == nil,
              "preload failure cannot produce a heartbeat — nothing is pinned")
        vm.stopLive()
        vm.deleteSession()
    }

    // Engine that won't start is the same outcome.
    do {
        resetSeams()
        LiveSessionViewModel.availableMemoryGB = { 24 }
        let manager = OllamaManager()
        manager.engineAvailable = false
        let vm = LiveSessionViewModel()
        vm.startLive(context: PreCallContext(), settings: liveSettings(), ollamaManager: manager)
        try? await Task.sleep(for: .milliseconds(500))
        check(vm.sessionModelState?.pinnedModel == nil,
              "engine failure settles deterministic",
              "state: \(String(describing: vm.sessionModelState))")
        vm.stopLive()
        vm.deleteSession()
    }

    // No fitting model stays deterministic through the recap: the recap is
    // the heaviest call and must not resurrect a model on its own.
    do {
        resetSeams()
        var preloaded: [String] = []
        LiveSessionViewModel.availableMemoryGB = { 2 }        // nothing fits
        LiveSessionViewModel.preloadModel = { preloaded.append($0); return nil }
        let vm = LiveSessionViewModel()
        let settings = liveSettings()
        let manager = OllamaManager()
        vm.startLive(context: PreCallContext(), settings: settings, ollamaManager: manager)
        try? await Task.sleep(for: .milliseconds(500))
        check(vm.sessionModelState?.pinnedModel == nil,
              "no fitting model -> deterministic",
              "state: \(String(describing: vm.sessionModelState))")
        if let cap = AudioCaptureManager.last {
            cap.onUtterance?(Utterance(t: 1, speaker: "You", text: "Words for a recap.", endT: 3))
        }
        vm.stopLive()
        try? await Task.sleep(for: .milliseconds(500))
        check(preloaded.isEmpty,
              "no fitting model stays deterministic through recap — nothing loaded",
              "preloaded: \(preloaded)")
        check(vm.meetingReview != nil, "a deterministic recap is still produced",
              "utterances: \(vm.utterances.count), state: \(String(describing: vm.sessionModelState)), generating: \(vm.isGeneratingSummary)")
        vm.deleteSession()
    }

    // Mock mode never constructs an LLM client.
    do {
        resetSeams()
        var preloaded: [String] = []
        LiveSessionViewModel.availableMemoryGB = { 64 }
        LiveSessionViewModel.preloadModel = { preloaded.append($0); return nil }
        let vm = LiveSessionViewModel()
        let settings = liveSettings()
        settings.useMock = true
        let manager = OllamaManager()
        vm.startLive(context: PreCallContext(), settings: settings, ollamaManager: manager)
        try? await Task.sleep(for: .milliseconds(500))
        check(vm.sessionModelState?.pinnedModel == nil,
              "mock mode is deterministic",
              "state: \(String(describing: vm.sessionModelState))")
        check(preloaded.isEmpty, "mock mode never constructs an LLM client",
              "preloaded: \(preloaded)")
        vm.stopLive()
        vm.deleteSession()
    }

    // Stop during the model refresh: the continuation must stand down.
    do {
        resetSeams()
        var preloaded: [String] = []
        LiveSessionViewModel.availableMemoryGB = { 24 }
        LiveSessionViewModel.preloadModel = { preloaded.append($0); return nil }
        let vm = LiveSessionViewModel()
        let settings = liveSettings()
        let (stream, cont) = AsyncStream<Void>.makeStream()
        settings.refreshGate = (stream, cont)
        let manager = OllamaManager()
        vm.startLive(context: PreCallContext(), settings: settings, ollamaManager: manager)
        try? await Task.sleep(for: .milliseconds(400))   // parked inside refresh
        vm.stopLive()
        cont.yield(())                                    // release the refresh
        try? await Task.sleep(for: .milliseconds(400))
        check(vm.sessionModelState?.pinnedModel == nil,
              "Stop during model refresh never pins",
              "state: \(String(describing: vm.sessionModelState))")
        check(preloaded.isEmpty,
              "Stop during model refresh never preloads", "preloaded: \(preloaded)")
        vm.deleteSession()
    }

    // Stop during preload: the load lands, but for a session that has ended,
    // so it must be released rather than pinned.
    do {
        resetSeams()
        var unloaded: [String] = []
        LiveSessionViewModel.availableMemoryGB = { 24 }
        let (stream, cont) = AsyncStream<Void>.makeStream()
        LiveSessionViewModel.preloadModel = { _ in
            var it = stream.makeAsyncIterator()
            _ = await it.next()
            return nil
        }
        LiveSessionViewModel.unloadModel = { unloaded.append($0) }
        let vm = LiveSessionViewModel()
        let settings = liveSettings()
        let manager = OllamaManager()
        vm.startLive(context: PreCallContext(), settings: settings, ollamaManager: manager)
        try? await Task.sleep(for: .milliseconds(400))   // parked inside preload
        vm.stopLive()
        cont.yield(())                                    // preload completes late
        try? await Task.sleep(for: .milliseconds(500))
        check(vm.sessionModelState?.pinnedModel == nil,
              "Stop during preload never pins",
              "state: \(String(describing: vm.sessionModelState))")
        check(unloaded.contains("qwen3.5:4b"),
              "a preload that lands after Stop is released, not left resident",
              "unloaded: \(unloaded)")
        vm.deleteSession()
    }

    // Session B starts while A is still activating: A must not pin, and A's
    // model must be released.
    do {
        resetSeams()
        var unloaded: [String] = []
        LiveSessionViewModel.availableMemoryGB = { 24 }
        let (stream, cont) = AsyncStream<Void>.makeStream()
        var firstPreload = true
        LiveSessionViewModel.preloadModel = { _ in
            if firstPreload {
                firstPreload = false
                var it = stream.makeAsyncIterator()
                _ = await it.next()
            }
            return nil
        }
        LiveSessionViewModel.unloadModel = { unloaded.append($0) }
        let vm = LiveSessionViewModel()
        let settingsA = liveSettings("qwen3.5:9b")
        let managerA = OllamaManager()
        vm.startLive(context: PreCallContext(), settings: settingsA, ollamaManager: managerA)
        try? await Task.sleep(for: .milliseconds(400))   // A parked in preload
        let idA = vm.sessionModelState?.sessionID

        vm.stopLive()
        let settings = liveSettings("qwen3.5:4b")
        let manager = OllamaManager()
        vm.startLive(context: PreCallContext(), settings: settings, ollamaManager: manager)
        let idB = vm.sessionModelState?.sessionID
        check(idA != nil && idB != nil && idA != idB,
              "each session gets its own UUID", "A: \(String(describing: idA)), B: \(String(describing: idB))")
        cont.yield(())                                    // A's preload lands late
        try? await Task.sleep(for: .milliseconds(600))
        check(vm.sessionModelState?.sessionID == idB,
              "the completing A activation does not overwrite B's state",
              "state: \(String(describing: vm.sessionModelState))")
        check(vm.sessionModelState?.pinnedModel != "qwen3.5:9b",
              "A's model is never pinned onto B",
              "state: \(String(describing: vm.sessionModelState))")
        check(unloaded.contains("qwen3.5:9b"),
              "A's late preload is released", "unloaded: \(unloaded)")
        vm.stopLive()
        vm.deleteSession()
    }

    // An empty session (mis-click, no words) still frees its model.
    do {
        resetSeams()
        var unloaded: [String] = []
        LiveSessionViewModel.availableMemoryGB = { 24 }
        LiveSessionViewModel.preloadModel = { _ in nil }
        LiveSessionViewModel.unloadModel = { unloaded.append($0) }
        let vm = LiveSessionViewModel()
        let settings = liveSettings("qwen3.5:4b")
        let manager = OllamaManager()
        vm.startLive(context: PreCallContext(), settings: settings, ollamaManager: manager)
        try? await Task.sleep(for: .milliseconds(500))
        check(vm.sessionModelState?.pinnedModel == "qwen3.5:4b", "precondition: pinned")
        vm.stopLive()                                     // no utterances at all
        try? await Task.sleep(for: .milliseconds(500))
        check(unloaded.contains("qwen3.5:4b"),
              "empty session unloads its model", "unloaded: \(unloaded)")
        vm.deleteSession()
    }

    // Multilingual review content keeps the parser's five English headers,
    // while legacy files (no Language header) ask for dominant-language output.
    let spanishPrompt = PromptBuilder.buildPostCallReviewPrompt(
        nudges: [], transcript: "Them: El presupuesto está aprobado.",
        context: PreCallContext(), durationMinutes: 10, languageName: "Spanish")
    check(spanishPrompt.system.contains("Write all section content in Spanish"),
          "review prompt pins Spanish content")
    check(spanishPrompt.system.contains("five literal header lines")
          && spanishPrompt.user.hasSuffix("starting with TITLE:."),
          "review prompt preserves five-header parser contract")
    let legacyPrompt = PromptBuilder.buildPostCallReviewPrompt(
        nudges: [], transcript: "Them: Bonjour.", context: PreCallContext(),
        durationMinutes: 5)
    check(legacyPrompt.system.contains("transcript's dominant language"),
          "legacy review infers dominant transcript language")

    let parsedSpanish = MeetingReview.parse(llmText: """
        TITLE:
        Presupuesto aprobado
        SUMMARY:
        El equipo aprobó el presupuesto.
        KEY TAKEAWAYS:
        - El lanzamiento sigue previsto.
        NEXT STEPS:
        - Ana — enviar el contrato — viernes
        NEXT MEETING FOCUS:
        Confirmar la fecha final.
        """)
    check(parsedSpanish.summary == "El equipo aprobó el presupuesto."
          && parsedSpanish.takeaways.count == 1
          && parsedSpanish.actionItems.count == 1,
          "Spanish content parses under English headers")

    do {
        let settings = SettingsViewModel()
        settings.meetingLanguage = .spanish
        let vm = LiveSessionViewModel()
        vm.startLive(context: PreCallContext(), settings: settings)
        try? await Task.sleep(for: .milliseconds(300))
        AudioCaptureManager.last?.onPartialText?("You", "Confirmamos el presupuesto.")
        vm.stopLive()
        let saved = vm.savedPath.flatMap {
            try? String(contentsOfFile: $0, encoding: .utf8)
        } ?? ""
        check(vm.sessionLanguage?.code == "es" && saved.contains("**Language:** es"),
              "explicit Spanish is snapshotted and persisted")
        vm.deleteSession()
    }

    resetSeams()
}

await runTests()
exit(fail ? 1 : 0)
