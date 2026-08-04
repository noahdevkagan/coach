import Foundation
import SwiftUI
import ServiceManagement

@MainActor @Observable
final class SettingsViewModel {
    var selectedModel: String
    var rubricPath: String
    var availableModels: [OllamaModel] = []
    var ollamaReachable: Bool = false
    var hasCheckedModels: Bool = false
    var useMock: Bool = false
    var showModelCatalog: Bool = false

    /// Engine handle so on-demand flows (model downloads) can start
    /// Ollama first — it is otherwise only started lazily at session start.
    @ObservationIgnored weak var ollamaManager: OllamaManager?

    /// Tier-2 semantic coaching: local-LLM heartbeat during live sessions.
    var semanticCoachEnabled: Bool {
        didSet { UserDefaults.standard.set(semanticCoachEnabled, forKey: "semanticCoachEnabled") }
    }

    /// Session clock in the coaching overlay's ambient row. Default on.
    var showOverlayClock: Bool {
        didSet { UserDefaults.standard.set(showOverlayClock, forKey: "showOverlayClock") }
    }

    /// Default scheduled length for calls started without the goal form
    /// (0 = not timed). Arms the time-based nudges on one-click Go Live.
    var defaultMeetingMinutes: Int {
        didSet { UserDefaults.standard.set(defaultMeetingMinutes, forKey: "defaultMeetingMinutes") }
    }

    /// Open MeetingCoach automatically at login. Default on — meeting
    /// detection only helps if the app is running after a restart.
    var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            Self.applyLaunchAtLogin(launchAtLogin)
        }
    }

    // Download state
    var downloadingModel: String?
    var downloadProgress: Double = 0
    var downloadStatus: String = ""
    var downloadError: String?

    private var downloadTask: Task<Void, Never>?

    init() {
        self.semanticCoachEnabled = UserDefaults.standard.object(forKey: "semanticCoachEnabled") as? Bool ?? true
        self.showOverlayClock = UserDefaults.standard.object(forKey: "showOverlayClock") as? Bool ?? true
        self.defaultMeetingMinutes = UserDefaults.standard.object(forKey: "defaultMeetingMinutes") as? Int ?? 0
        let storedLaunchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool
        self.launchAtLogin = storedLaunchAtLogin ?? true
        self.selectedModel = UserDefaults.standard.string(forKey: "selectedModel")
            ?? "qwen3.5:9b"
        self.rubricPath = UserDefaults.standard.string(forKey: "rubricPath") ?? ""
        if self.rubricPath.isEmpty {
            AppSupport.ensureLayout()
            self.rubricPath = AppSupport.activeRubricURL.path
        }
        // One-time v2 migration to the default cut. Only the app-managed
        // active.yaml is touched — a custom rubricPath is the user's own
        // file and is never rewritten. No-op once migrated (or if the user
        // ever tuned builtins themselves).
        if self.rubricPath == AppSupport.activeRubricURL.path {
            Rubric.migrateToV2(at: AppSupport.activeRubricURL) { label in
                AppSupport.backupActiveRubric(label: label)
            }
        }
        // First run (or first launch after updating to this version):
        // register the login item so the default actually takes effect.
        // After that, only an explicit toggle re-applies — if the user
        // turns the item off in System Settings > Login Items instead of
        // here, we don't re-register behind their back on every launch.
        if storedLaunchAtLogin == nil {
            UserDefaults.standard.set(true, forKey: "launchAtLogin")
            Self.applyLaunchAtLogin(true)
        }
    }

    /// Register/unregister the app as a login item. Release builds only:
    /// a Debug build registering `SMAppService.mainApp` would point the
    /// login item at the dev build's path — and since dev and installed
    /// builds share the bundle ID (and UserDefaults), it would hijack the
    /// installed app's registration.
    static func applyLaunchAtLogin(_ enabled: Bool) {
        #if DEBUG
        mclog("[Settings] launchAtLogin=\(enabled) (debug build — not touching the login item)")
        #else
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard service.status != .enabled else { return }
                try service.register()
            } else {
                guard service.status == .enabled || service.status == .requiresApproval else { return }
                try service.unregister()
            }
        } catch {
            mclog("[Settings] Launch-at-login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        #endif
    }

    func save() {
        UserDefaults.standard.set(selectedModel, forKey: "selectedModel")
        UserDefaults.standard.set(rubricPath, forKey: "rubricPath")
    }

    func refreshModels() async {
        let client = OllamaClient(model: selectedModel)
        do {
            availableModels = try await client.listModels()
            ollamaReachable = true
        } catch {
            ollamaReachable = false
            // Engine not running ≠ no models. The engine starts lazily, so
            // the launch-time check always used to land here with an empty
            // list — and the UI re-showed model onboarding over a store
            // with gigabytes of pulled models. The manifests directory is
            // the on-disk truth; read it instead.
            availableModels = Self.installedModelsOnDisk()
        }
        hasCheckedModels = true
    }

    /// Models present in the app's own store, straight from the manifests
    /// tree (manifests/<registry>/<namespace>/<model>/<tag>), no engine
    /// needed. Size comes from summing the manifest's layer sizes.
    static func installedModelsOnDisk() -> [OllamaModel] {
        let manifests = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MeetingCoach/ollama/manifests")
        let fm = FileManager.default
        var models: [OllamaModel] = []
        guard let walker = fm.enumerator(at: manifests,
                                         includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        for case let file as URL in walker {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            // …/manifests/registry.ollama.ai/library/qwen3.5/9b → "qwen3.5:9b"
            // (the "library" namespace is implicit, matching `ollama list`).
            let parts = file.pathComponents.drop { $0 != "manifests" }.dropFirst()
            guard parts.count >= 3 else { continue }
            let tag = parts.last!
            let model = parts[parts.index(parts.endIndex, offsetBy: -2)]
            let namespace = parts.count >= 4 ? parts[parts.index(parts.endIndex, offsetBy: -3)] : "library"
            let name = namespace == "library" ? "\(model):\(tag)" : "\(namespace)/\(model):\(tag)"

            var size: Int64 = 0
            if let data = try? Data(contentsOf: file),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                for layer in json["layers"] as? [[String: Any]] ?? [] {
                    size += (layer["size"] as? Int64) ?? Int64(layer["size"] as? Int ?? 0)
                }
            }
            models.append(OllamaModel(name: name, size: size, parameterSize: ""))
        }
        return models.sorted { $0.name < $1.name }
    }

    /// One-time zero-click pull of the recommended model, run after the
    /// Parakeet download finishes (or immediately when it was cached).
    /// The attempted-flag is set only when a pull genuinely starts: an
    /// engine that can't come up (dev build without the vendored runtime,
    /// broken install) may try again next launch — that is not a user
    /// cancel. Once a pull starts, Cancel is respected forever.
    static let autoModelPullAttemptedKey = "autoModelPullAttempted"

    func autoDownloadRecommendedIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Self.autoModelPullAttemptedKey),
              !useMock, downloadingModel == nil else { return }
        await refreshModels()
        guard availableModels.isEmpty else {
            // Already set up (any model counts) — never auto-pull over it.
            UserDefaults.standard.set(true, forKey: Self.autoModelPullAttemptedKey)
            return
        }
        // Don't fill a nearly-full disk with a ~6.6 GB surprise.
        if let free = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < 12_000_000_000 {
            mclog("[Settings] Auto-pull skipped: low disk (\(free) bytes free)")
            return
        }
        guard let manager = ollamaManager, await manager.ensureRunning() else {
            mclog("[Settings] Auto-pull skipped: engine unavailable")
            return
        }
        guard let recommended = modelCatalog.first else { return }
        UserDefaults.standard.set(true, forKey: Self.autoModelPullAttemptedKey)
        mclog("[Settings] Auto-pulling recommended model \(recommended.fullName)")
        downloadModel(recommended)
    }

    func downloadModel(_ catalogModel: CatalogModel) {
        let fullName = catalogModel.fullName
        downloadingModel = fullName
        downloadProgress = 0
        downloadStatus = "Starting..."
        downloadError = nil

        let client = OllamaClient(model: fullName)
        downloadTask = Task {
            // The engine starts lazily at session time, so on a fresh
            // install nothing is listening yet — bring it up first.
            if let manager = self.ollamaManager {
                self.downloadStatus = "Starting engine..."
                guard await manager.ensureRunning() else {
                    self.downloadError = "error: Could not start the local AI engine."
                    self.downloadingModel = nil
                    return
                }
                self.downloadStatus = "Starting..."
            }
            for await progress in await client.pullModel(name: fullName) {
                self.downloadStatus = progress.status
                if progress.total > 0 {
                    self.downloadProgress = progress.fraction
                    self.downloadStatus = progress.sizeLabel
                }
                if progress.isComplete {
                    self.downloadingModel = nil
                    self.selectedModel = fullName
                    self.save()
                    await self.refreshModels()
                    return
                }
                if progress.status.hasPrefix("error") {
                    self.downloadError = progress.status
                    self.downloadingModel = nil
                    return
                }
            }
            // Stream ended without success
            if self.downloadingModel != nil {
                self.downloadingModel = nil
                await self.refreshModels()
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadingModel = nil
        downloadProgress = 0
        downloadStatus = ""
    }

    func deleteModel(_ name: String) async {
        let client = OllamaClient(model: name)
        do {
            try await client.deleteModel(name: name)
            await refreshModels()
            if selectedModel == name {
                selectedModel = availableModels.first?.name ?? ""
            }
        } catch {
            downloadError = "Failed to delete: \(error.localizedDescription)"
        }
    }

    func isInstalled(_ catalogModel: CatalogModel) -> Bool {
        availableModels.contains { $0.name == catalogModel.fullName }
    }

    func loadRubricOrDefault() throws -> Rubric {
        if !rubricPath.isEmpty {
            if FileManager.default.fileExists(atPath: rubricPath) {
                return try loadRubric(from: URL(fileURLWithPath: rubricPath))
            }
            mclog("[Settings] Rubric not found at \(rubricPath) — falling back to built-in default rubric")
        }
        return .builtInDefault
    }
}
