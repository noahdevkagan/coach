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

    // Download state
    var downloadingModel: String?
    var downloadProgress: Double = 0
    var downloadStatus: String = ""
    var downloadError: String?

    private var downloadTask: Task<Void, Never>?

    /// Names of locally installed models (for quick lookup)
    var installedModelNames: Set<String> {
        Set(availableModels.map { $0.name })
    }

    init() {
        self.selectedModel = UserDefaults.standard.string(forKey: "selectedModel")
            ?? "qwen2.5:7b-instruct"
        self.rubricPath = UserDefaults.standard.string(forKey: "rubricPath") ?? ""
        if self.rubricPath.isEmpty {
            let defaultPath = NSString("~/dev/coach/rubrics/personal.yaml").expandingTildeInPath
            if FileManager.default.fileExists(atPath: defaultPath) {
                self.rubricPath = defaultPath
            }
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
        let path = rubricPath.isEmpty ? nil : rubricPath
        if let path, FileManager.default.fileExists(atPath: path) {
            return try loadRubric(from: URL(fileURLWithPath: path))
        }
        return Rubric(
            name: "default", version: 1,
            cadence: Cadence(), window: TranscriptWindow(),
            output: OutputConfig(), signals: [])
    }
}
