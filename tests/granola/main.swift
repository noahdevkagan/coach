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

exit(failures == 0 ? 0 : 1)
