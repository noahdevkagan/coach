import Foundation

// MeetingCoach signal-engine benchmark.
//
// Replays saved session transcripts (~/Documents/MeetingCoach/session_*.md)
// through the deterministic SignalEngine and scores the result:
//
//   - nag proxy:        nudges per 10 min, overall and per type
//   - useful agreement: replay fires within ±90s of a nudge you rated useful
//   - nag agreement:    replay fires within ±90s of a nudge you rated annoying/wrong
//                       (each one that STOPS firing is a win)
//
// Every run appends a JSON line to bench/history.jsonl tagged with the git
// commit, so scores are comparable across engine versions over time.
//
// Usage: bench/run.sh [--label "baseline"] [--sessions <dir>]

// MARK: - Session parsing

struct RatedNudge {
    let t: TimeInterval
    let type: NudgeType?
    let feedback: NudgeFeedback?
}

struct BenchSession {
    let name: String
    let utterances: [Utterance]
    let ratedNudges: [RatedNudge]
    let goal: String
    let scheduledMinutes: Int
    var durationMinutes: Double {
        guard let last = utterances.last else { return 0 }
        return max(last.t / 60, 1)
    }
}

func parseSession(_ url: URL) -> BenchSession? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let lines = text.components(separatedBy: .newlines)

    let transcriptLine = try! NSRegularExpression(pattern: #"^- \[(\d+):(\d{2})\] ([^:]+): (.*)$"#)
    // Type key is \w or "custom:<id>" — sessions written since the rubric
    // unification use the key form for rubric-defined signals.
    let nudgeLine = try! NSRegularExpression(pattern: #"^- \[(\d+):(\d{2})\] \*\*([\w:]+)\*\* \(\w+\): .*?(?:\| feedback: (\w+))?$"#)

    var utterances: [Utterance] = []
    var rated: [RatedNudge] = []
    var goal = ""
    var scheduledMinutes = 30
    var section = ""

    for line in lines {
        if line.hasPrefix("## ") {
            section = String(line.dropFirst(3))
            continue
        }
        if line.hasPrefix("**Goal:** ") {
            goal = String(line.dropFirst("**Goal:** ".count))
            continue
        }
        if line.hasPrefix("**Scheduled Duration:** ") {
            scheduledMinutes = Int(line.dropFirst("**Scheduled Duration:** ".count)
                .replacingOccurrences(of: " min", with: "")) ?? 30
            continue
        }

        let range = NSRange(line.startIndex..., in: line)
        if section == "Transcript",
           let m = transcriptLine.firstMatch(in: line, range: range) {
            let ns = line as NSString
            let mm = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let ss = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let speaker = ns.substring(with: m.range(at: 3))
            let body = ns.substring(with: m.range(at: 4))
            guard !body.isEmpty else { continue }
            utterances.append(Utterance(t: Double(mm * 60 + ss), speaker: speaker, text: body))
        } else if section == "Nudges",
                  let m = nudgeLine.firstMatch(in: line, range: range) {
            let ns = line as NSString
            let mm = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let ss = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let type = NudgeType(rawValue: ns.substring(with: m.range(at: 3)))
            var feedback: NudgeFeedback?
            if m.range(at: 4).location != NSNotFound {
                feedback = NudgeFeedback(rawValue: ns.substring(with: m.range(at: 4)))
            }
            rated.append(RatedNudge(t: Double(mm * 60 + ss), type: type, feedback: feedback))
        }
    }

    guard utterances.count >= 10 else { return nil }
    return BenchSession(
        name: url.deletingPathExtension().lastPathComponent,
        utterances: utterances,
        ratedNudges: rated,
        goal: goal,
        scheduledMinutes: scheduledMinutes
    )
}

// MARK: - Replay

/// Replay a session through the engine the way the live loop drives it:
/// evaluate on every new utterance plus a 5-second tick grid.
func replay(_ session: BenchSession) -> [Nudge] {
    let context = PreCallContext(
        meetingGoal: session.goal,
        scheduledDurationMinutes: session.scheduledMinutes
    )
    var engine = SignalEngine(context: context)
    var fired: [Nudge] = []

    let utts = session.utterances
    var i = 0
    var nextTick: TimeInterval = 5
    let end = utts.last!.t

    var current: [Utterance] = []
    current.reserveCapacity(utts.count)

    var elapsed: TimeInterval = 0
    while elapsed < end || i < utts.count {
        let nextUtt = i < utts.count ? utts[i].t : .infinity
        if nextUtt <= nextTick {
            current.append(utts[i])
            elapsed = nextUtt
            i += 1
        } else {
            elapsed = nextTick
            nextTick += 5
        }
        guard !current.isEmpty else { continue }
        fired.append(contentsOf: engine.evaluate(utterances: current, elapsed: elapsed, context: context))
    }
    return fired
}

// MARK: - Scoring

struct SessionScore {
    let name: String
    let minutes: Double
    let nudges: [Nudge]
    let usefulMatched: Int
    let usefulTotal: Int
    let nagMatched: Int
    let nagTotal: Int

    var per10Min: Double { Double(nudges.count) / minutes * 10 }
}

func score(_ session: BenchSession, matchWindow: TimeInterval = 90) -> SessionScore {
    let fired = replay(session)

    func matched(_ r: RatedNudge) -> Bool {
        fired.contains { n in
            (r.type == nil || n.type == r.type) && abs(n.timestamp - r.t) <= matchWindow
        }
    }

    let useful = session.ratedNudges.filter { $0.feedback == .useful }
    let nag = session.ratedNudges.filter { $0.feedback == .annoying || $0.feedback == .wrong }

    return SessionScore(
        name: session.name,
        minutes: session.durationMinutes,
        nudges: fired,
        usefulMatched: useful.filter(matched).count,
        usefulTotal: useful.count,
        nagMatched: nag.filter(matched).count,
        nagTotal: nag.count
    )
}

// MARK: - Main

var label = "run"
var sessionsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/MeetingCoach")

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    switch args.removeFirst() {
    case "--label": label = args.isEmpty ? label : args.removeFirst()
    case "--sessions": if !args.isEmpty { sessionsDir = URL(fileURLWithPath: args.removeFirst()) }
    default: break
    }
}

let files = ((try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.lastPathComponent.hasPrefix("session_") && $0.pathExtension == "md" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !files.isEmpty else {
    print("No session files found in \(sessionsDir.path)")
    exit(1)
}

var scores: [SessionScore] = []
var perType: [String: Int] = [:]

print("session                          min   nudges  /10min  useful   nag-hits")
print(String(repeating: "-", count: 78))
for file in files {
    guard let session = parseSession(file) else { continue }
    let s = score(session)
    scores.append(s)
    for n in s.nudges { perType[n.type.rawValue, default: 0] += 1 }
    let useful = s.usefulTotal > 0 ? "\(s.usefulMatched)/\(s.usefulTotal)" : "-"
    let nag = s.nagTotal > 0 ? "\(s.nagMatched)/\(s.nagTotal)" : "-"
    print("\(s.name.padding(toLength: 32, withPad: " ", startingAt: 0)) \(String(format: "%4.0f", s.minutes))  \(String(format: "%5d", s.nudges.count))   \(String(format: "%5.1f", s.per10Min))   \(useful.padding(toLength: 7, withPad: " ", startingAt: 0)) \(nag)")
}

let totalMinutes = scores.map(\.minutes).reduce(0, +)
let totalNudges = scores.map(\.nudges.count).reduce(0, +)
let per10 = totalMinutes > 0 ? Double(totalNudges) / totalMinutes * 10 : 0
let usefulMatched = scores.map(\.usefulMatched).reduce(0, +)
let usefulTotal = scores.map(\.usefulTotal).reduce(0, +)
let nagMatched = scores.map(\.nagMatched).reduce(0, +)
let nagTotal = scores.map(\.nagTotal).reduce(0, +)

print(String(repeating: "-", count: 78))
print("TOTAL: \(scores.count) sessions, \(String(format: "%.0f", totalMinutes)) min, \(totalNudges) nudges (\(String(format: "%.1f", per10))/10min)")
print("Per type: \(perType.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
if usefulTotal > 0 { print("Useful agreement: \(usefulMatched)/\(usefulTotal)") }
if nagTotal > 0 { print("Nag agreement (lower is better): \(nagMatched)/\(nagTotal)") }

// MARK: - History

let commit = { () -> String in
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
}()

// Corpus fingerprint: scores are only comparable across commits when they
// replay the SAME sessions. New meetings on the machine change the corpus,
// which moves the numbers for non-engine reasons — the fingerprint lets
// consumers (push gate, humans) compare like with like.
let corpus = { () -> String in
    let names = scores.map(\.name).sorted().joined(separator: ",")
    var hash: UInt64 = 5381
    for byte in names.utf8 { hash = hash &* 33 &+ UInt64(byte) }
    return String(format: "%08x", hash & 0xFFFF_FFFF)
}()

let record: [String: Any] = [
    "date": ISO8601DateFormatter().string(from: Date()),
    "commit": commit,
    "label": label,
    "corpus": corpus,
    "sessions": scores.count,
    "minutes": Int(totalMinutes),
    "nudges": totalNudges,
    "per10min": (per10 * 10).rounded() / 10,
    "perType": perType,
    "usefulMatched": usefulMatched,
    "usefulTotal": usefulTotal,
    "nagMatched": nagMatched,
    "nagTotal": nagTotal,
]

let historyURL = URL(fileURLWithPath: "bench/history.jsonl")
if let data = try? JSONSerialization.data(withJSONObject: record),
   let line = String(data: data, encoding: .utf8) {
    let entry = line + "\n"
    if FileManager.default.fileExists(atPath: historyURL.path),
       let handle = try? FileHandle(forWritingTo: historyURL) {
        handle.seekToEndOfFile()
        handle.write(entry.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? entry.write(to: historyURL, atomically: true, encoding: .utf8)
    }
    print("\nRecorded to bench/history.jsonl (\(label) @ \(commit))")
}
