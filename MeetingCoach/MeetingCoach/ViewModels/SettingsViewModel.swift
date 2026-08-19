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

    /// Global selection, resolved and snapshotted by LiveSessionViewModel at
    /// meeting start. Changing it begins the needed download but never mutates
    /// a session already in progress.
    var meetingLanguage: MeetingLanguageSelection {
        didSet {
            UserDefaults.standard.set(meetingLanguage.rawValue,
                                      forKey: MeetingLanguageSelection.defaultsKey)
            ParakeetDownloadState.shared.startIfNeeded(
                for: meetingLanguage.resolved().preferredEngine)
        }
    }

    var resolvedMeetingLanguage: ResolvedMeetingLanguage { meetingLanguage.resolved() }

    /// Engine handle so on-demand flows (model downloads) can start
    /// Ollama first — it is otherwise only started lazily at session start.
    @ObservationIgnored weak var ollamaManager: OllamaManager?

    /// Tier-2 semantic coaching: local-LLM heartbeat during live sessions.
    /// Surfaced in Settings as "AI coaching". Off = transcript-first mode:
    /// no model preload or engine launch at session start; on-demand AI
    /// review of saved sessions still works.
    var semanticCoachEnabled: Bool {
        didSet {
            UserDefaults.standard.set(semanticCoachEnabled, forKey: "semanticCoachEnabled")
            // Re-enabling restores the zero-click setup that disabling
            // deferred — otherwise the pull only happens on the next launch.
            // The method's own guards make this a no-op when a model is
            // already installed or the pull already ran.
            if semanticCoachEnabled, !oldValue {
                Task { await self.autoDownloadRecommendedIfNeeded() }
            }
        }
    }

    /// Master switch for the floating coaching overlay. Off = nudges only
    /// appear in the main window's coach rail. Default on.
    var showCoachOverlay: Bool {
        didSet { UserDefaults.standard.set(showCoachOverlay, forKey: "showCoachOverlay") }
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
        self.meetingLanguage = MeetingLanguageSelection.current
        self.semanticCoachEnabled = UserDefaults.standard.object(forKey: "semanticCoachEnabled") as? Bool ?? true
        self.showCoachOverlay = UserDefaults.standard.object(forKey: "showCoachOverlay") as? Bool ?? true
        self.showOverlayClock = UserDefaults.standard.object(forKey: "showOverlayClock") as? Bool ?? true
        self.defaultMeetingMinutes = UserDefaults.standard.object(forKey: "defaultMeetingMinutes") as? Int ?? 0
        let storedLaunchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool
        self.launchAtLogin = storedLaunchAtLogin ?? true
        // Fresh installs default to the RAM-aware recommendation — the old
        // one-size qwen3.5:9b default swapped 8–16 GB Macs into a freeze.
        self.selectedModel = UserDefaults.standard.string(forKey: "selectedModel")
            ?? recommendedCatalogModel.fullName
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

    /// The model LLM calls should actually use: the selection when it's
    /// installed, otherwise the first installed model. The selection can
    /// point at a model whose download never finished — seen 2026-08-04:
    /// selection qwen3.5:9b, store gemma4:e4b, and every LLM feature
    /// (review, name suggestions, semantic coach) silently failed with
    /// "model not found" and degraded to heuristics.
    /// Second guard (2026-08-05): an installed-but-too-big selection would
    /// freeze the whole Mac at load time — fall back to a model that fits;
    /// modelFitNote tells the user.
    /// Fallback order (2026-08-06): the RAM-tiered recommendation when it's
    /// installed, else the smallest fitting install. The old "largest that
    /// fits" pick silently overrode the RAM tiering — a 24 GB Mac with a
    /// 9.6 GB gemma lying around ran it instead of the intended ~3.4 GB
    /// qwen, costing ~6 GB of a meeting's headroom for marginal quality.
    var effectiveModel: String {
        guard !availableModels.isEmpty else { return selectedModel }
        let fitting = availableModels.filter { ModelMemory.fits($0) }
        if let selected = availableModels.first(where: { $0.name == selectedModel }),
           ModelMemory.fits(selected) {
            return selectedModel
        }
        if let recommended = fitting.first(where: { $0.name == recommendedCatalogModel.fullName }) {
            return recommended.name
        }
        return fitting.min(by: { $0.size < $1.size })?.name
            ?? availableModels.first?.name ?? selectedModel
    }

    /// User-facing one-liner when the selected model can't run comfortably
    /// on this Mac. nil when everything is fine.
    var modelFitNote: String? {
        guard let selected = availableModels.first(where: { $0.name == selectedModel }),
              !ModelMemory.fits(selected) else { return nil }
        let ram = ModelMemory.physicalRAMGB
        if effectiveModel != selectedModel {
            return "\(selectedModel) needs more memory than this Mac (\(ram) GB) can spare — using \(effectiveModel) instead."
        }
        return "\(selectedModel) needs more memory than this Mac (\(ram) GB) can spare. AI features may fail — download a smaller model."
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
        // Transcript-first users opted out of the LLM — no surprise ~6.6 GB
        // pull. Flag stays unset so re-enabling AI coaching restores the
        // one-time zero-click setup.
        guard semanticCoachEnabled else {
            mclog("[Settings] Auto-pull skipped: AI coaching is off")
            return
        }
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
        let recommended = recommendedCatalogModel
        UserDefaults.standard.set(true, forKey: Self.autoModelPullAttemptedKey)
        mclog("[Settings] Auto-pulling recommended model \(recommended.fullName)")
        downloadModel(recommended)
    }

    /// `forSessionFallback` is the low-memory banner's path: pull the small
    /// ladder rung so *future* busy sessions have something that fits —
    /// without hijacking the user's selected model, and without the post-pull
    /// verification load (the user is mid-meeting on a machine that just
    /// proved it has no memory to spare).
    func downloadModel(_ catalogModel: CatalogModel, forSessionFallback: Bool = false) {
        let fullName = catalogModel.fullName
        // The catalog UI already hides models that can't fit; this is the
        // backstop for every other path to a pull.
        guard catalogModel.fitsThisMac else {
            downloadError = "error: \(fullName) needs \(catalogModel.minRAMGB) GB of memory — this Mac has \(ModelMemory.physicalRAMGB) GB."
            return
        }
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
                    if !forSessionFallback {
                        self.selectedModel = fullName
                        self.save()
                    }
                    await self.refreshModels()
                    // Freshly pulled = the user is right here in Settings;
                    // a short warm-up window verifies it loads (OOM surfaces
                    // now, not mid-meeting) without pinning RAM for hours.
                    // Skipped for the fallback pull — the user is mid-meeting
                    // on a machine that just proved it has none to spare.
                    if !forSessionFallback {
                        await self.verifyDownloadedModelLoads()
                    }
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

    /// Surfaced in the Model section when the launch-time load failed —
    /// most importantly Ollama's own "model requires more system memory
    /// (X GiB) than is available (Y GiB)", which used to appear only in
    /// the log while the meeting-time load froze the Mac.
    var modelWarmupError: String?

    /// Load the effective model into the engine now (meeting detected,
    /// session start, download finish) instead of at the first mid-meeting
    /// LLM call — model-load at minute one of a call was the worst possible
    /// timing: peak memory pressure plus a stalled first heartbeat.
    /// Warmed around meetings, not at launch (2026-08-06): the launch
    /// warm-up held multi-GB of KV/compute memory for 2h on Macs that
    /// weren't in a meeting at all. In-call num_ctx (4096) is requested so
    /// the heartbeat's first call reuses this runner instead of respawning.
    /// Memory-preflights first: a model that doesn't fit is never loaded
    /// (loading it IS the freeze), it's reported via modelFitNote.
    /// The model to load given what's free on this Mac *right now*, or nil to
    /// stay deterministic. `effectiveModel` answers the static question (does
    /// it fit this machine); this answers the live one (does it fit today's
    /// workload). Callers should refresh the installed list first — a stale
    /// list makes the ladder step down to something that isn't there.
    func modelForCurrentMemory() -> String? {
        guard !useMock else { return effectiveModel }
        // Memory unreadable — don't second-guess the user's choice.
        guard let availableGB = ModelMemory.availableGB else { return effectiveModel }
        let resolved = ModelMemory.modelForCurrentMemory(chosen: effectiveModel,
                                                         installed: availableModels,
                                                         availableGB: availableGB)
        if resolved != effectiveModel {
            mclog(String(format: "[Memory] %.1f GB free — %@ instead of %@",
                         availableGB, resolved ?? "deterministic coaching", effectiveModel))
        }
        return resolved
    }

    /// Offered by the low-memory banner: the smallest ladder rung, when it
    /// isn't installed yet. nil once it is (or nothing small enough exists) —
    /// the banner's button disappears the moment the pull completes.
    var fallbackModelSuggestion: CatalogModel? {
        ModelMemory.fallbackSuggestion(installed: availableModels)
    }

    /// Verifies a freshly pulled model actually loads, so an OOM surfaces in
    /// Settings rather than mid-meeting. Deliberately NOT a general warm-up:
    /// sessions preload their own choice once capture is up and free memory
    /// is real (see LiveSessionViewModel.activateSessionModel), and a second
    /// warming path is how two runners end up resident at once.
    func verifyDownloadedModelLoads(keepAlive: String = "10m") async {
        guard !useMock, downloadingModel == nil else { return }
        await refreshModels()
        let name = effectiveModel
        guard let model = availableModels.first(where: { $0.name == name }),
              ModelMemory.fits(model) else {
            mclog("[Settings] Load check skipped: \(name) doesn't fit in \(ModelMemory.physicalRAMGB) GB RAM")
            return
        }
        guard let manager = ollamaManager, await manager.ensureRunning() else {
            mclog("[Settings] Load check skipped: engine unavailable")
            return
        }
        if let error = await OllamaClient(model: name, numCtx: 4096).preload(keepAlive: keepAlive) {
            modelWarmupError = "Couldn't load \(name): \(error)"
            mclog("[Settings] Load check of \(name) failed: \(error)")
        } else {
            modelWarmupError = nil
            mclog("[Settings] Load check passed for \(name)")
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
