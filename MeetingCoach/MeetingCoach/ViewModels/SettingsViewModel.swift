import Foundation
import SwiftUI

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

    // Download state
    var downloadingModel: String?
    var downloadProgress: Double = 0
    var downloadStatus: String = ""
    var downloadError: String?

    private var downloadTask: Task<Void, Never>?

    init() {
        self.semanticCoachEnabled = UserDefaults.standard.object(forKey: "semanticCoachEnabled") as? Bool ?? true
        self.selectedModel = UserDefaults.standard.string(forKey: "selectedModel")
            ?? "qwen2.5:7b-instruct"
        self.rubricPath = UserDefaults.standard.string(forKey: "rubricPath") ?? ""
        if self.rubricPath.isEmpty {
            AppSupport.ensureLayout()
            self.rubricPath = AppSupport.activeRubricURL.path
        }
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
            availableModels = []
        }
        hasCheckedModels = true
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
