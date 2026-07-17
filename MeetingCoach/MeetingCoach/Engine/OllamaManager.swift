import AppKit
import Foundation
import os

/// Manages the embedded Ollama binary lifecycle.
/// Starts it on app launch, stops it on quit. Users never see it.
@MainActor @Observable
final class OllamaManager {
    enum Status: Equatable {
        case stopped
        case starting
        case running
        case error(String)
    }

    var status: Status = .stopped

    init() {
        // The embedded server is a plain child process — take it down with
        // the app or every session leaks an `ollama serve`.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }
    }

    private var process: Process?
    private let port: Int = 11434
    private let logger = Logger(subsystem: "com.coach.MeetingCoach", category: "OllamaManager")

    /// Last time the engine was auto-restarted after dying unexpectedly.
    /// One restart per window — external kills recover invisibly, a
    /// crash-looping engine still surfaces to the user.
    private var lastAutoRestart = Date.distantPast
    private let autoRestartWindow: TimeInterval = 300

    /// The directory containing ollama and its dylibs inside the app bundle.
    private var ollamaDir: URL? {
        // Strategy 1: Bundle.main.resourceURL/ollama/
        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent("ollama")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("ollama").path) {
                return candidate
            }
        }
        // Strategy 2: Relative to the executable (../Resources/ollama/)
        if let execURL = Bundle.main.executableURL {
            let candidate = execURL
                .deletingLastPathComponent()        // MacOS/
                .deletingLastPathComponent()        // Contents/
                .appendingPathComponent("Resources/ollama")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("ollama").path) {
                return candidate
            }
        }
        // Strategy 3: Bundle resource lookup
        if let url = Bundle.main.url(forResource: "ollama", withExtension: nil, subdirectory: "ollama") {
            return url.deletingLastPathComponent()
        }
        return nil
    }

    /// The path to the embedded ollama binary.
    private var embeddedOllamaURL: URL? {
        ollamaDir?.appendingPathComponent("ollama")
    }

    /// Data directory for models — stored in Application Support so models
    /// persist across app updates.
    private var modelsDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MeetingCoach/ollama")
    }

    /// True when the app's own model store has at least one pulled model.
    private var appHasLocalModels: Bool {
        let manifests = modelsDir.appendingPathComponent("manifests")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: manifests.path)) ?? []
        return !contents.isEmpty
    }

    /// Start the embedded Ollama server.
    func start() {
        guard status != .running && status != .starting else { return }

        // A server already on our port can be a leftover embedded engine
        // (which serves our models) or a system Ollama (which usually
        // doesn't). Use it only when it actually has models to offer, or
        // when we have none of our own either. Otherwise the app would bind
        // to an empty server and wrongly re-show model onboarding while
        // 20+ GB of pulled models sit unused in our store.
        if let systemModels = systemOllamaModelCount() {
            if systemModels > 0 || !appHasLocalModels {
                logger.info("Using ollama already on port \(self.port) (\(systemModels) models)")
                status = .running
                return
            }
            status = .error("Another Ollama is running without your models — quit Ollama.app (or `brew services stop ollama`), then Retry.")
            return
        }

        guard let ollamaBin = embeddedOllamaURL, let ollamaDir = ollamaDir else {
            NSLog("[OllamaManager] No embedded ollama and no system ollama")
            status = .error("Ollama not running. Start Ollama.app first.")
            return
        }
        logger.info("Found embedded ollama at: \(ollamaBin.path)")

        status = .starting

        // Ensure models directory exists
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        // Make binaries executable (in case code signing stripped permissions)
        for bin in ["ollama", "llama-server", "llama-quantize"] {
            let path = ollamaDir.appendingPathComponent(bin).path
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }

        let proc = Process()
        proc.executableURL = ollamaBin
        proc.arguments = ["serve"]
        proc.currentDirectoryURL = ollamaDir
        proc.environment = [
            "OLLAMA_HOST": "127.0.0.1:\(port)",
            "OLLAMA_MODELS": modelsDir.path,
            "OLLAMA_LLM_LIBRARY": ollamaDir.path,
            // DYLD_LIBRARY_PATH may be stripped by SIP, so also set runner paths
            "DYLD_LIBRARY_PATH": ollamaDir.path,
            "PATH": ollamaDir.path + ":/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
        ]

        // Log file for ollama output (helpful for debugging)
        let logFile = modelsDir.appendingPathComponent("ollama.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logFile)
        proc.standardOutput = logHandle ?? FileHandle.nullDevice
        proc.standardError = logHandle ?? FileHandle.nullDevice

        proc.terminationHandler = { [weak self] process in
            logHandle?.closeFile()
            Task { @MainActor in
                guard let self else { return }
                guard self.status == .running || self.status == .starting else { return }
                self.logger.warning("Embedded ollama terminated (code \(process.terminationStatus))")
                self.process = nil

                // Unexpected death (external kill, engine blip): restart
                // once per window before bothering the user.
                if Date().timeIntervalSince(self.lastAutoRestart) > self.autoRestartWindow {
                    self.lastAutoRestart = Date()
                    self.status = .stopped
                    self.logger.info("Auto-restarting embedded ollama")
                    mclog("[OllamaManager] engine died (code \(process.terminationStatus)) — auto-restarting")
                    self.start()
                    return
                }

                // Second death inside the window — fall back or surface it.
                if let systemModels = self.systemOllamaModelCount(), systemModels > 0 {
                    self.logger.info("Falling back to system ollama")
                    self.status = .running
                } else {
                    self.status = .error("Local AI engine stopped — instant nudges still work. Retry restores AI nudges.")
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
            logger.info("Started embedded ollama (PID \(proc.processIdentifier))")

            // Poll until the server is ready
            Task {
                await waitForReady()
            }
        } catch {
            status = .error("Failed to start: \(error.localizedDescription)")
            logger.error("Failed to start ollama: \(error)")
        }
    }

    /// Start the engine if needed and wait until it accepts requests.
    /// For flows that need Ollama on demand (e.g. model downloads from
    /// onboarding) before any session has lazily started it.
    /// Returns false if the engine can't come up within ~15s.
    func ensureRunning() async -> Bool {
        if status == .running {
            // A previously-detected server may have died since (e.g. the
            // user quit Ollama.app) — verify before trusting the status.
            if await OllamaClient().isReachable() { return true }
            status = .stopped
        }
        if status != .starting {
            start()
        }
        for _ in 0..<30 {
            switch status {
            case .running: return true
            case .error: return false
            default: try? await Task.sleep(for: .milliseconds(500))
            }
        }
        return false
    }

    /// Stop the embedded Ollama server.
    func stop() {
        guard let proc = process, proc.isRunning else {
            status = .stopped
            return
        }
        logger.info("Stopping embedded ollama (PID \(proc.processIdentifier))")
        proc.terminate()
        process = nil
        status = .stopped
    }

    /// Poll until Ollama responds on its API port.
    private func waitForReady() async {
        let client = OllamaClient()
        for attempt in 1...30 {
            try? await Task.sleep(for: .milliseconds(500))
            let reachable = await client.isReachable()
            if reachable {
                logger.info("Ollama ready after \(attempt) attempts")
                status = .running
                return
            }
        }
        // After 15 seconds, give up
        if status == .starting {
            status = .error("Ollama started but not responding")
        }
    }

    /// Check if a system-installed ollama is already running.
    private func systemOllamaAvailable() -> Bool {
        systemOllamaModelCount() != nil
    }

    /// nil when nothing answers on the port; otherwise how many models the
    /// server there offers. Distinguishes a leftover embedded engine (has
    /// our models) from a bare system Ollama (usually has none).
    private func systemOllamaModelCount() -> Int? {
        // Quick synchronous check — try to connect
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/tags") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        var count: Int?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                count = (json["models"] as? [[String: Any]])?.count ?? 0
            }
            sem.signal()
        }.resume()
        sem.wait()
        return count
    }
}
