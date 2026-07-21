import Foundation

// meetingcoach-mcp — a minimal stdio MCP server exposing saved MeetingCoach
// sessions to agents (Claude Code, Codex, …). Local-first by construction:
// stdio only, reads the same session files the app writes, no network, no
// daemon — it runs only while an agent host is talking to it.
//
// Tools: list_sessions · search_transcripts(query) · get_transcript(file).
// Search is the app's own TranscriptSearch (compiled into this target), so
// in-app search and agent search can never drift.
//
// Register with:  claude mcp add meetingcoach -- <path-to-this-binary>
// (the app's Advanced sidebar has a copy button for exactly that command)

enum Server {
    /// The app and this helper are separate processes with separate defaults
    /// domains — resolve the sessions folder the way the app does, reading
    /// the app's persisted choice when present.
    static func resolveSessionsDir() -> URL {
        if let override = ProcessInfo.processInfo.environment["MEETINGCOACH_SESSIONS_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        if let domain = UserDefaults.standard.persistentDomain(forName: "com.coach.MeetingCoach"),
           let path = domain[AppSupport.sessionFolderKey] as? String, !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/MeetingCoach", isDirectory: true)
    }

    static func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    static func result(_ id: Any, _ payload: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": payload]
    }

    static func rpcError(_ id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    static func textContent(_ text: String, isError: Bool = false) -> [String: Any] {
        var payload: [String: Any] = ["content": [["type": "text", "text": text]]]
        if isError { payload["isError"] = true }
        return payload
    }

    static var toolDefs: [[String: Any]] {
        [
            ["name": "list_sessions",
             "description": "List saved MeetingCoach meeting sessions, newest first: file name, date, size.",
             "inputSchema": ["type": "object",
                             "properties": [String: Any](),
                             "required": [String]()]],
            ["name": "search_transcripts",
             "description": "Full-text search over every saved meeting transcript. Returns matching spoken lines with session file, timestamp, and speaker.",
             "inputSchema": ["type": "object",
                             "properties": ["query": ["type": "string",
                                                      "description": "Text to find (case-insensitive)"]],
                             "required": ["query"]]],
            ["name": "get_transcript",
             "description": "Return the full saved markdown for one session — file name as returned by list_sessions or search_transcripts.",
             "inputSchema": ["type": "object",
                             "properties": ["file": ["type": "string",
                                                     "description": "Session file name, e.g. session_2026-07-20_14-32.md"]],
                             "required": ["file"]]],
        ]
    }

    static func handleToolCall(name: String, args: [String: Any], dir: URL) -> [String: Any] {
        switch name {
        case "list_sessions":
            let files = TranscriptSearch.sessionFiles(in: dir)
            guard !files.isEmpty else {
                return textContent("No saved sessions in \(dir.path).")
            }
            let lines = files.map { url -> String in
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
                let size = bytes.map { " (\(max(1, $0 / 1024)) KB)" } ?? ""
                return "- \(url.lastPathComponent) — \(TranscriptSearch.title(for: url))\(size)"
            }
            return textContent(lines.joined(separator: "\n"))

        case "search_transcripts":
            guard let query = args["query"] as? String,
                  !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                return textContent("Missing required argument: query", isError: true)
            }
            let hits = TranscriptSearch.search(query, in: dir)
            guard !hits.isEmpty else {
                return textContent("No mentions of \"\(query)\" in saved transcripts.")
            }
            let lines = hits.map {
                "\($0.file.lastPathComponent) [\($0.timestamp)] \($0.speaker): \($0.text)"
            }
            return textContent(lines.joined(separator: "\n"))

        case "get_transcript":
            guard let file = args["file"] as? String else {
                return textContent("Missing required argument: file", isError: true)
            }
            // Session files only, no traversal: this tool exposes saved
            // transcripts, not the filesystem.
            guard !file.contains("/"), !file.contains(".."),
                  file.hasPrefix("session_"), file.hasSuffix(".md") else {
                return textContent("Not a session file: \(file)", isError: true)
            }
            let url = dir.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return textContent("No such session: \(file)", isError: true)
            }
            return textContent(text)

        default:
            return textContent("Unknown tool: \(name)", isError: true)
        }
    }

    static func run() {
        let dir = resolveSessionsDir()

        while let raw = readLine(strippingNewline: true) {
            guard !raw.isEmpty,
                  let data = raw.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let method = msg["method"] as? String else { continue }
            let id = msg["id"]

            switch method {
            case "initialize":
                guard let id else { break }
                let params = msg["params"] as? [String: Any]
                send(result(id, [
                    "protocolVersion": params?["protocolVersion"] as? String ?? "2024-11-05",
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "meetingcoach",
                                   "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"],
                ]))
            case "ping":
                if let id { send(result(id, [:])) }
            case "tools/list":
                if let id { send(result(id, ["tools": toolDefs])) }
            case "tools/call":
                guard let id else { break }
                let params = msg["params"] as? [String: Any] ?? [:]
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                send(result(id, handleToolCall(name: name, args: args, dir: dir)))
            default:
                // Notifications (no id) are fine to ignore; unknown requests
                // get the standard method-not-found.
                if let id { send(rpcError(id, code: -32601, message: "Method not found: \(method)")) }
            }
        }
    }
}

Server.run()
