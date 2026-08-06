import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print("granola \(name): \(ok ? "PASS" : "FAIL")")
    if !ok { failures += 1 }
}

let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("granola-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }

let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
let report = try GranolaImporter.importCSV(fixture, into: dir)
check("imports the record (CRLF header survives)", report.imported == 1)

let files = TranscriptSearch.sessionFiles(in: dir)
check("writes one session file", files.count == 1)
let content = files.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
check("title is the document_title", content.contains("**Title:** Roadmap Sync"))
check("summary lands in notes (empty notes column)", content.contains("Discussed the roadmap"))
check("transcript imported as session lines",
      content.contains("- [--:--] Speaker A: Morning, ready to start?"))
check("wrapped transcript line folds into its turn",
      content.contains("First item is the budget. and the hiring plan too."))
check("utterance count matches turns", content.contains("**Utterances:** 4"))
let again = try GranolaImporter.importCSV(fixture, into: dir)
check("re-import dedupes", again.imported == 0 && again.skippedExisting == 1)

// A transcript-less shell (what the broken pre-0.12.0 importer wrote) must
// be healed by a re-import, not skipped forever behind its dedupe marker.
let shellDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("granola-shell-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: shellDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: shellDir) }
let shellFile = shellDir.appendingPathComponent("session_2026-08-01_10-30.md")
try """
# Meeting Coach Session — 2026-08-01_10-30
**Title:** Roadmap Sync (renamed by user)
**Utterances:** 0
**Nudges:** 0
**Engine:** Granola import
**Imported-From:** granola:fixture-0001
""".write(to: shellFile, atomically: true, encoding: .utf8)

let heal = try GranolaImporter.importCSV(fixture, into: shellDir)
check("shell re-import heals instead of skipping",
      heal.imported == 0 && heal.updated == 1 && heal.skippedExisting == 0)
let healed = (try? String(contentsOf: shellFile, encoding: .utf8)) ?? ""
check("healed shell gained the transcript",
      healed.contains("## Transcript")
          && healed.contains("- [--:--] Speaker A: Morning, ready to start?"))
check("healed shell keeps the user's rename",
      healed.contains("**Title:** Roadmap Sync (renamed by user)"))
check("healed utterance count updated", healed.contains("**Utterances:** 4"))
let third = try GranolaImporter.importCSV(fixture, into: shellDir)
check("healed file then dedupes normally",
      third.imported == 0 && third.updated == 0 && third.skippedExisting == 1)

exit(failures == 0 ? 0 : 1)
