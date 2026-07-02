import Foundation

// Transcript backtest: replay ONE meeting transcript through both coaching
// tiers and print every nudge that would have fired live, with timestamps.
//
// Tier 1 (deterministic signals) replays exactly like the live loop.
// Tier 2 (semantic LLM) replays the 60s heartbeat against local Ollama.
//
// Usage: bench/backtest.sh <transcript> [--model qwen2.5:14b-instruct]
//        [--no-semantic] [--goal "meeting goal"] [--minutes 90]

func mclog(_ msg: String) {
    FileHandle.standardError.write(("  " + msg + "\n").data(using: .utf8)!)
}

@main
struct Backtest {
    static func fmt(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }

    static func main() async {
        var path: String?
        var model = "qwen2.5:14b-instruct"
        var runSemantic = true
        var goal = ""
        var scheduledMinutes = 90
        var meetingType: MeetingType?

        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--model": if !args.isEmpty { model = args.removeFirst() }
            case "--no-semantic": runSemantic = false
            case "--goal": if !args.isEmpty { goal = args.removeFirst() }
            case "--minutes": if !args.isEmpty { scheduledMinutes = Int(args.removeFirst()) ?? 90 }
            case "--type": if !args.isEmpty { meetingType = MeetingType(rawValue: args.removeFirst()) }
            default: path = a
            }
        }

        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("Usage: backtest <transcript path> [--model m] [--no-semantic] [--goal g] [--minutes n]")
            exit(1)
        }

        let utterances = TranscriptParser.parse(text)
        guard !utterances.isEmpty else {
            print("No utterances parsed from \(path)")
            exit(1)
        }

        let end = utterances.last!.t
        var context = PreCallContext(meetingGoal: goal, scheduledDurationMinutes: scheduledMinutes)
        context.meetingType = meetingType

        print("Parsed \(utterances.count) utterances, \(fmt(end)) duration")
        let speakers = Dictionary(grouping: utterances, by: \.speaker).mapValues(\.count)
        print("Speakers: \(speakers.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        print("")

        // MARK: Tier 1 — deterministic replay (utterance events + 5s ticks)

        var engine = SignalEngine(context: context)
        var tier1: [Nudge] = []
        var i = 0
        var nextTick: TimeInterval = 5
        var current: [Utterance] = []
        current.reserveCapacity(utterances.count)
        var elapsed: TimeInterval = 0
        while elapsed < end || i < utterances.count {
            let nextUtt = i < utterances.count ? utterances[i].t : .infinity
            if nextUtt <= nextTick {
                current.append(utterances[i])
                elapsed = nextUtt
                i += 1
            } else {
                elapsed = nextTick
                nextTick += 5
            }
            guard !current.isEmpty else { continue }
            tier1.append(contentsOf: engine.evaluate(utterances: current, elapsed: elapsed, context: context))
        }

        print("== Tier 1 (deterministic): \(tier1.count) nudges ==")
        for n in tier1 {
            print("  [\(fmt(n.timestamp))] \(n.type.rawValue): \(n.text)")
        }
        print("")

        // MARK: Tier 2 — semantic replay (60s heartbeat, live-identical gating)

        guard runSemantic else { return }

        let coach = await SemanticCoach(model: model)
        var fed = 0
        var tier2: [Nudge] = []

        var t: TimeInterval = 90
        let passes = Int((end - t) / SemanticCoach.heartbeatSeconds) + 1
        print("== Tier 2 (semantic, \(model)): \(passes) passes ==")

        while t <= end {
            while fed < utterances.count, utterances[fed].t <= t {
                fed += 1
            }
            let nudges = await coach.analyze(utterances: Array(utterances.prefix(fed)), elapsed: t, context: context)
            for n in nudges {
                tier2.append(n)
                print("  [\(fmt(n.timestamp))] \(n.type.rawValue): \(n.text)")
            }
            FileHandle.standardError.write("pass @ \(fmt(t)) done\n".data(using: .utf8)!)
            t += SemanticCoach.heartbeatSeconds
        }
        print("== Tier 2 total: \(tier2.count) nudges ==")
    }
}
