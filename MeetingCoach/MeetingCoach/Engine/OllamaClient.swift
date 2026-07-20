import Foundation

struct OllamaModel: Identifiable, Sendable {
    let name: String
    let size: Int64
    let parameterSize: String
    var id: String { name }

    var sizeLabel: String {
        let gb = Double(size) / 1_073_741_824
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(size) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

/// Progress update from a model pull operation.
struct PullProgress: Sendable {
    let status: String
    let completed: Int64
    let total: Int64

    var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }

    var isComplete: Bool {
        status == "success"
    }

    var sizeLabel: String {
        guard total > 0 else { return status }
        let completedGB = Double(completed) / 1_073_741_824
        let totalGB = Double(total) / 1_073_741_824
        return String(format: "%.1f / %.1f GB", completedGB, totalGB)
    }
}

/// A model available in the Ollama catalog for download.
struct CatalogModel: Identifiable, Sendable {
    let name: String
    let tag: String
    let description: String
    let parameterSize: String
    let diskSize: String

    var id: String { "\(name):\(tag)" }
    var fullName: String { "\(name):\(tag)" }
}

/// Curated catalog of models good for meeting coaching. The first entry is
/// the onboarding recommendation. Reviewed periodically (last: 2026-07)
/// against what the semantic coach actually needs: strong conversational
/// judgment + strict JSON on a 60s heartbeat, on 8–16GB Apple Silicon.
/// Thinking-mode models (DeepSeek R1 etc.) are deliberately absent — they
/// burn heartbeat latency on reasoning tokens before the JSON starts.
let modelCatalog: [CatalogModel] = [
    // -- Recommended --
    CatalogModel(name: "qwen3.5", tag: "9b",
                 description: "Qwen 3.5 — best judgment + rock-solid JSON, MLX-fast on Apple Silicon. Recommended.",
                 parameterSize: "9B", diskSize: "~6.6 GB"),
    CatalogModel(name: "gemma4", tag: "e4b",
                 description: "Google Gemma 4 Edge — efficient MoE, 128K context, tool calling",
                 parameterSize: "4B eff", diskSize: "~9.6 GB"),
    // -- Compact / fast --
    CatalogModel(name: "qwen3.5", tag: "4b",
                 description: "Lighter Qwen 3.5 — the pick for 8GB Macs",
                 parameterSize: "4B", diskSize: "~3.4 GB"),
    CatalogModel(name: "gemma4", tag: "e2b",
                 description: "Google Gemma 4 Edge — smallest, great for quick scans",
                 parameterSize: "2B eff", diskSize: "~7.2 GB"),
    // -- Larger / higher quality --
    CatalogModel(name: "qwen3.5", tag: "27b",
                 description: "Qwen 3.5 27B — top judgment for nuanced signals, needs 32GB RAM",
                 parameterSize: "27B", diskSize: "~17 GB"),
    CatalogModel(name: "gemma4", tag: "12b",
                 description: "Google Gemma 4 12B — stronger reasoning, still fast on Apple Silicon",
                 parameterSize: "12B", diskSize: "~8.1 GB"),
    CatalogModel(name: "gemma4", tag: "26b",
                 description: "Google Gemma 4 26B MoE — best quality, needs 16GB+ RAM",
                 parameterSize: "26B MoE", diskSize: "~16 GB"),
    CatalogModel(name: "phi4", tag: "latest",
                 description: "Microsoft Phi-4, strong reasoning for its size",
                 parameterSize: "14B", diskSize: "~9.1 GB"),
    // -- Alternatives --
    CatalogModel(name: "qwen2.5", tag: "7b-instruct",
                 description: "Previous default — reliable JSON, fine to keep if already installed",
                 parameterSize: "7B", diskSize: "~4.7 GB"),
    CatalogModel(name: "granite4", tag: "3b",
                 description: "IBM Granite 4 — tiny, strong instruction-following, Apache licensed",
                 parameterSize: "3B", diskSize: "~2.1 GB"),
    CatalogModel(name: "mistral", tag: "7b-instruct-v0.3",
                 description: "Mistral 7B, fast and reliable",
                 parameterSize: "7B", diskSize: "~4.1 GB"),
    CatalogModel(name: "glm4", tag: "9b",
                 description: "THUDM GLM-4 — strong bilingual, good structured output",
                 parameterSize: "9B", diskSize: "~5.5 GB"),
]

enum OllamaError: Error, LocalizedError {
    case serverError(String)
    var errorDescription: String? {
        switch self { case .serverError(let msg): return "Ollama: \(msg)" }
    }
}

/// Talks to a local Ollama daemon. Enforces loopback-only (mirrors llm.py).
actor OllamaClient {
    let baseURL: URL
    let model: String
    let timeout: TimeInterval

    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    init(model: String = "qwen2.5:7b-instruct",
         baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
         timeout: TimeInterval = 120) {
        let host = baseURL.host() ?? baseURL.host ?? ""
        guard Self.loopbackHosts.contains(host) else {
            fatalError("LLM base URL host '\(host)' is not loopback. Refusing — inference must stay local.")
        }
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
    }

    /// POST /api/chat — Ollama native endpoint (faster than OpenAI-compat, supports num_ctx)
    func complete(system: String, user: String) async throws -> String {
        let url = baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "options": [
                "temperature": 0.3,
                "num_ctx": 8192,
                "num_predict": 512,
            ],
            "stream": false,
            "think": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        mclog("[Ollama] Response status=\(httpStatus), bytes=\(data.count)")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data.prefix(500), encoding: .utf8) ?? "(binary)"
            mclog("[Ollama] ERROR: response is not JSON: \(raw)")
            return "[]"
        }

        if let errorMsg = json["error"] as? String {
            mclog("[Ollama] ERROR from server: \(errorMsg)")
            throw OllamaError.serverError(errorMsg)
        }

        guard let message = json["message"] as? [String: Any] else {
            mclog("[Ollama] ERROR: missing message in response keys=\(json.keys)")
            return "[]"
        }
        var content = message["content"] as? String ?? ""
        // Fallback: if content is empty but thinking has content (thinking models),
        // try to extract JSON from the thinking field
        if content.isEmpty, let thinking = message["thinking"] as? String, !thinking.isEmpty {
            mclog("[Ollama] Content empty, checking thinking field (\(thinking.count) chars)")
            content = thinking
        }
        mclog("[Ollama] Got \(content.count) chars from model")
        return content
    }

    /// GET /api/tags — list locally available models
    func listModels() async throws -> [OllamaModel] {
        let url = baseURL.appendingPathComponent("api/tags")
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return []
        }
        return models.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            let size = dict["size"] as? Int64 ?? 0
            let details = dict["details"] as? [String: Any] ?? [:]
            let paramSize = details["parameter_size"] as? String ?? ""
            return OllamaModel(name: name, size: size, parameterSize: paramSize)
        }
    }

    /// POST /api/pull — download a model, streaming progress updates
    func pullModel(name: String) -> AsyncStream<PullProgress> {
        let url = baseURL.appendingPathComponent("api/pull")
        return AsyncStream { continuation in
            Task {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 3600 // 1 hour for large downloads

                let payload: [String: Any] = ["name": name, "stream": true]
                request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

                do {
                    let (bytes, _) = try await URLSession.shared.bytes(for: request)
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        // The registry reports failures as {"error": ...} lines,
                        // not via the status key — surface them or the download
                        // silently resets with no message.
                        if let serverError = json["error"] as? String {
                            // Registry errors can be multi-line (412 upgrade notices);
                            // collapse to one line so the UI label stays readable.
                            let compact = serverError
                                .components(separatedBy: .whitespacesAndNewlines)
                                .filter { !$0.isEmpty }
                                .joined(separator: " ")
                                .prefix(200)
                            continuation.yield(PullProgress(status: "error: \(compact)", completed: 0, total: 0))
                            break
                        }
                        let status = json["status"] as? String ?? ""
                        let completed = json["completed"] as? Int64 ?? 0
                        let total = json["total"] as? Int64 ?? 0
                        continuation.yield(PullProgress(status: status, completed: completed, total: total))
                        if status == "success" { break }
                    }
                } catch {
                    continuation.yield(PullProgress(status: "error: \(error.localizedDescription)", completed: 0, total: 0))
                }
                continuation.finish()
            }
        }
    }

    /// DELETE /api/delete — remove a model
    func deleteModel(name: String) async throws {
        let url = baseURL.appendingPathComponent("api/delete")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
    }

    /// Check if Ollama is reachable
    func isReachable() async -> Bool {
        do {
            _ = try await listModels()
            return true
        } catch {
            return false
        }
    }
}
