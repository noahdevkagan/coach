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

    /// Start the embedded Ollama server.
    func start() {
        guard status != .running && status != .starting else { return }

        // Check system ollama FIRST — most common case (user has Ollama.app running)
        if systemOllamaAvailable() {
            logger.info("System ollama already running on port \(self.port)")
            NSLog("[OllamaManager] System ollama detected — using it")
            status = .running
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
                if self.status == .running || self.status == .starting {
                    self.logger.warning("Embedded ollama terminated (code \(process.terminationStatus))")
                    // Fall back to system ollama if available
                    if self.systemOllamaAvailable() {
                        self.logger.info("Falling back to system ollama")
                        self.status = .running
                    } else {
                        self.status = .error("Engine stopped (code \(process.terminationStatus))")
                    }
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
        // Quick synchronous check — try to connect
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        var reachable = false
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            reachable = data != nil
            sem.signal()
        }.resume()
        sem.wait()
        return reachable
    }
}
