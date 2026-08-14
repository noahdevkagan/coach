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

/// RAM-fit rules for local models, in one place. A model is "comfortable"
/// when its weights plus ~1.5 GB (KV cache + runner) stay within ~70% of
/// unified memory — beyond that macOS swaps mid-meeting, which the user
/// experiences as a whole-machine freeze, not an error message. Every
/// `minRAMGB` in the catalog below was derived from this same formula.
enum ModelMemory {
    static var physicalRAMGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }

    static func fits(weightBytes: Int64, ramGB: Int = physicalRAMGB) -> Bool {
        let budget = Int64(ramGB) * 1_073_741_824 * 7 / 10
        return weightBytes + 1_500_000_000 <= budget
    }

    /// Fit check for an installed model: catalog entries carry a reviewed
    /// `minRAMGB` (MoE models break the pure size heuristic); anything the
    /// user pulled outside the catalog falls back to the size formula.
    static func fits(_ model: OllamaModel) -> Bool {
        if let entry = modelCatalog.first(where: { $0.fullName == model.name }) {
            return entry.fitsThisMac
        }
        guard model.size > 0 else { return true }
        return fits(weightBytes: model.size)
    }

    // MARK: - Current workload
    //
    // `fits(_:)` above answers a static question: could this Mac ever run this
    // model comfortably. It cannot see that a browser, a video call and two
    // Electron apps are holding 20 GB *right now* — which is how a 32 GB Mac
    // swaps on a model whose minRAMGB is 16 and passes every static check.
    // The two rules are complementary, not redundant: the 70% rule reserves a
    // fraction of TOTAL memory for the machine's general needs, while these
    // reserve headroom inside what is actually free at this moment. A model
    // must pass both before it is loaded.

    /// KV cache + runner process overhead on top of the weights themselves.
    /// Same figure the static rule uses.
    static let runtimeOverheadBytes: Int64 = 1_500_000_000

    /// Kept free beyond the model itself: live capture (Parakeet weights, the
    /// diarizer, audio buffers) plus normal growth over a meeting.
    ///
    /// Provisional — chosen conservatively, NOT measured per-machine. It wants
    /// calibration against a real session before anyone tightens it.
    static let currentHeadroomGB: Double = 3

    /// Free + inactive pages, in GB.
    ///
    /// A heuristic, and deliberately labelled as one. Inactive pages are
    /// reclaimable but not free — reclaiming dirty ones costs writeback — and
    /// the figure moves between this reading and the model finishing its load.
    /// Compressed and purgeable pages are excluded rather than counted, which
    /// keeps the estimate from inflating. nil if the kernel call fails, which
    /// callers treat as "don't second-guess the user".
    static var availableGB: Double? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // Queried, not read from `vm_kernel_page_size`: that global is a
        // mutable var and strict concurrency rejects it.
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let pages = Double(stats.free_count) + Double(stats.inactive_count)
        return pages * Double(pageSize) / 1_073_741_824
    }

    /// What loading this model will actually cost: its installed size plus
    /// KV/runner overhead.
    static func runtimeNeedGB(installedBytes: Int64) -> Double {
        Double(installedBytes + runtimeOverheadBytes) / 1_073_741_824
    }

    /// The model to load right now, or nil to run deterministic-only.
    ///
    /// Pure — available memory and the installed set are passed in — so the
    /// policy is testable at exact memory pressures instead of depending on
    /// whatever the test machine happens to be doing.
    ///
    /// Walks `recommendationLadder` rather than taking the largest model that
    /// still fits: largest-that-fits would prefer a bulkier, weaker model over
    /// a leaner, better one, the same trap the 2026-08-06 effectiveModel fix
    /// removed from the static path.
    static func modelForCurrentMemory(chosen: String,
                                      installed: [OllamaModel],
                                      availableGB: Double,
                                      headroomGB: Double = currentHeadroomGB) -> String? {
        candidatesForCurrentMemory(chosen: chosen, installed: installed,
                                   availableGB: availableGB,
                                   headroomGB: headroomGB).first
    }

    /// Load order for this session: the selected model first, then strictly
    /// smaller installed rungs to fall back to when a preload fails anyway
    /// (the heuristic is a snapshot; the OOM verdict is the engine's). Only
    /// smaller — a model that out-sizes one that just failed to load would
    /// fail harder.
    static func candidatesForCurrentMemory(chosen: String,
                                           installed: [OllamaModel],
                                           availableGB: Double,
                                           headroomGB: Double = currentHeadroomGB) -> [String] {
        // A model with no reported size can't be sized, and one that isn't
        // installed can't be loaded at all — both are unsafe. Treating either
        // as "fine" is how something oversized slips through: the optimistic
        // reading is exactly the one that ends in a swapping meeting.
        func safe(_ model: OllamaModel) -> Bool {
            guard model.size > 0 else { return false }
            return runtimeNeedGB(installedBytes: model.size) + headroomGB <= availableGB
        }
        func rung(_ name: String) -> OllamaModel? {
            guard let model = installed.first(where: { $0.name == name }),
                  safe(model) else { return nil }
            return model
        }

        var candidates: [OllamaModel] = []
        if let selected = rung(chosen) {
            candidates.append(selected)
        } else {
            for name in recommendationLadder {
                if let model = rung(name) { candidates.append(model); break }
            }
        }
        guard let first = candidates.first else { return [] }
        for name in recommendationLadder where name != first.name {
            if let model = rung(name), model.size < first.size {
                candidates.append(model)
            }
        }
        return candidates.map(\.name)
    }

    /// The download to offer when a session degrades for memory: the ladder's
    /// smallest rung, iff it isn't installed and can run on this Mac at all.
    /// When that rung is installed and still didn't fit, no download can
    /// help — offer nothing. RAM is injectable so the policy is testable
    /// at exact sizes (CI runners have less RAM than any supported Mac).
    static func fallbackSuggestion(installed: [OllamaModel],
                                   ramGB: Int = physicalRAMGB) -> CatalogModel? {
        guard let name = recommendationLadder.last,
              !installed.contains(where: { $0.name == name }),
              let entry = modelCatalog.first(where: { $0.fullName == name }),
              entry.minRAMGB <= ramGB else { return nil }
        return entry
    }
}

/// A model available in the Ollama catalog for download.
struct CatalogModel: Identifiable, Sendable {
    let name: String
    let tag: String
    let description: String
    let parameterSize: String
    let diskSize: String
    /// Minimum unified memory (GB) to run without swapping mid-meeting.
    let minRAMGB: Int

    var id: String { "\(name):\(tag)" }
    var fullName: String { "\(name):\(tag)" }

    var fitsThisMac: Bool { minRAMGB <= ModelMemory.physicalRAMGB }
}

/// The RAM-aware onboarding/auto-pull default. Only 32 GB+ Macs get the
/// flagship 9b: a real meeting means Zoom + a browser + live transcription
/// running alongside the model, so headroom beats benchmark points (the
/// old one-size default froze smaller Macs at exactly the wrong moment).
/// Step-down order when the Mac is too busy right now for the chosen model,
/// best first. Sizing decides which rung is reachable; this decides which
/// model is best at each rung. One family end to end — the heartbeat depends
/// on strict JSON, and swapping families to save a gigabyte trades that away.
///
/// The 27B is deliberately absent: a fallback should never be the largest
/// thing that happens to fit.
let recommendationLadder = ["qwen3.5:9b", "qwen3.5:4b", "granite4:3b"]

var recommendedCatalogModel: CatalogModel {
    let name = ModelMemory.physicalRAMGB >= 32 ? "qwen3.5:9b" : "qwen3.5:4b"
    return modelCatalog.first { $0.fullName == name } ?? modelCatalog[0]
}

/// Curated catalog of models good for meeting coaching. The first entry is
/// the onboarding recommendation. Reviewed periodically (last: 2026-07)
/// against what the semantic coach actually needs: strong conversational
/// judgment + strict JSON on a 60s heartbeat, on 8–16GB Apple Silicon.
/// Thinking-mode models (DeepSeek R1 etc.) are deliberately absent — they
/// burn heartbeat latency on reasoning tokens before the JSON starts.
let modelCatalog: [CatalogModel] = [
    // -- Recommended (see recommendedCatalogModel for the RAM-aware pick) --
    CatalogModel(name: "qwen3.5", tag: "9b",
                 description: "Qwen 3.5 — best judgment + rock-solid JSON, MLX-fast on Apple Silicon. The pick for 32 GB+ Macs.",
                 parameterSize: "9B", diskSize: "~6.6 GB", minRAMGB: 16),
    CatalogModel(name: "gemma4", tag: "e4b",
                 description: "Google Gemma 4 Edge — efficient MoE, 128K context, tool calling",
                 parameterSize: "4B eff", diskSize: "~9.6 GB", minRAMGB: 16),
    // -- Compact / fast --
    CatalogModel(name: "qwen3.5", tag: "4b",
                 description: "Lighter Qwen 3.5 — fast, light on memory, the pick for 8–16 GB Macs",
                 parameterSize: "4B", diskSize: "~3.4 GB", minRAMGB: 8),
    CatalogModel(name: "gemma4", tag: "e2b",
                 description: "Google Gemma 4 Edge — smallest Gemma, great for quick scans",
                 parameterSize: "2B eff", diskSize: "~7.2 GB", minRAMGB: 16),
    // -- Larger / higher quality --
    CatalogModel(name: "qwen3.5", tag: "27b",
                 description: "Qwen 3.5 27B — top judgment for nuanced signals",
                 parameterSize: "27B", diskSize: "~17 GB", minRAMGB: 32),
    CatalogModel(name: "gemma4", tag: "12b",
                 description: "Google Gemma 4 12B — stronger reasoning, still fast on Apple Silicon",
                 parameterSize: "12B", diskSize: "~8.1 GB", minRAMGB: 16),
    CatalogModel(name: "gemma4", tag: "26b",
                 description: "Google Gemma 4 26B MoE — best Gemma quality",
                 parameterSize: "26B MoE", diskSize: "~16 GB", minRAMGB: 32),
    CatalogModel(name: "phi4", tag: "latest",
                 description: "Microsoft Phi-4, strong reasoning for its size",
                 parameterSize: "14B", diskSize: "~9.1 GB", minRAMGB: 16),
    // -- Alternatives --
    CatalogModel(name: "qwen2.5", tag: "7b-instruct",
                 description: "Previous default — reliable JSON, fine to keep if already installed",
                 parameterSize: "7B", diskSize: "~4.7 GB", minRAMGB: 16),
    CatalogModel(name: "granite4", tag: "3b",
                 description: "IBM Granite 4 — tiny, strong instruction-following, Apache licensed",
                 parameterSize: "3B", diskSize: "~2.1 GB", minRAMGB: 8),
    CatalogModel(name: "mistral", tag: "7b-instruct-v0.3",
                 description: "Mistral 7B, fast and reliable",
                 parameterSize: "7B", diskSize: "~4.1 GB", minRAMGB: 8),
    CatalogModel(name: "glm4", tag: "9b",
                 description: "THUDM GLM-4 — strong bilingual, good structured output",
                 parameterSize: "9B", diskSize: "~5.5 GB", minRAMGB: 16),
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
    /// Context window requested per call. KV-cache memory scales linearly
    /// with this, so in-call callers (heartbeat, name inference) pass 4096 —
    /// their prompt is a 180s window — while the post-call review keeps the
    /// 8192 default for long transcripts. NB: changing num_ctx between
    /// requests makes Ollama respawn the runner, so keep it stable within
    /// a phase (all in-call = 4096; the one review reload is post-call).
    let numCtx: Int
    /// Sent on every generation request. Without it Ollama resets the
    /// runner's expiry to the server default (5m) on each call.
    let keepAlive: String

    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    init(model: String = "qwen2.5:7b-instruct",
         baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
         timeout: TimeInterval = 120,
         numCtx: Int = 8192,
         keepAlive: String = "10m") {
        let host = baseURL.host() ?? baseURL.host ?? ""
        guard Self.loopbackHosts.contains(host) else {
            fatalError("LLM base URL host '\(host)' is not loopback. Refusing — inference must stay local.")
        }
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        self.numCtx = numCtx
        self.keepAlive = keepAlive
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
                "num_ctx": numCtx,
                "num_predict": 512,
            ],
            "keep_alive": keepAlive,
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

    /// POST /api/generate with no prompt — Ollama's documented way to load
    /// a model into memory without generating anything. keep_alive keeps it
    /// resident so the first real call (mid-meeting, at peak memory
    /// pressure) doesn't pay multi-GB load time. Residency is not free:
    /// weights are mmap'd (reclaimable) but KV cache + compute buffers are
    /// dirty anonymous memory macOS cannot page out cheaply — hence warm
    /// only around meetings and unloadIfLoaded() when the work is done.
    /// Returns nil on success, or a user-showable error — Ollama's OOM
    /// message ("model requires more system memory … than is available")
    /// is exactly the clear error we want instead of a freeze.
    func preload(keepAlive: String = "30m") async -> String? {
        let url = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180 // cold load of a many-GB model
        // Options must match what complete() sends: a runner loaded with a
        // different num_ctx gets torn down and respawned on the first real
        // call, double-paying the load the warm-up was meant to save.
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "keep_alive": keepAlive,
            "options": ["num_ctx": numCtx],
        ])
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String {
                return error
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// GET /api/ps — models currently resident in the engine.
    func runningModels() async -> [String] {
        let url = baseURL.appendingPathComponent("api/ps")
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }

    /// Evict this client's model from engine memory if (and only if) it is
    /// actually resident — a bare keep_alive:0 on an unloaded model would
    /// load gigabytes just to free them. Multi-GB of RAM come back the
    /// moment there is no more work; warm-on-detect reloads before the
    /// next meeting.
    func unloadIfLoaded() async {
        guard await runningModels().contains(model) else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "keep_alive": 0,
        ])
        _ = try? await URLSession.shared.data(for: request)
        mclog("[Ollama] Unloaded \(model)")
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
