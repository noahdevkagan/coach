import FluidAudio
import Foundation
import Observation

/// Observable state for the ~600 MB Parakeet model download, so the UI can
/// show a real progress bar instead of "downloading in the background".
/// Replaces the old fire-and-forget ParakeetEngine.prefetchInBackground().
///
/// One app-wide instance; startIfNeeded() is safe to call from every launch
/// path (menu-bar label, main window, session start) — it no-ops when the
/// model is cached and coalesces concurrent callers onto the running task.
@MainActor
@Observable
final class ParakeetDownloadState {
    static let shared = ParakeetDownloadState()

    enum Phase: Equatable {
        case idle
        case downloading(fraction: Double, detail: String)
        case compiling
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    var isActive: Bool {
        switch phase {
        case .downloading, .compiling: return true
        default: return false
        }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var onReadyOnce: [@MainActor () -> Void] = []

    /// Start the download unless the model is cached or a download is
    /// already running. `onReady` fires exactly once when the model is
    /// available — immediately when cached, after the download otherwise,
    /// and never on failure (a retry that succeeds still fires it).
    func startIfNeeded(onReady: (@MainActor () -> Void)? = nil) {
        if ParakeetEngine.isCachedOnDisk {
            phase = .ready
            onReady?()
            return
        }
        if let onReady { onReadyOnce.append(onReady) }
        guard task == nil else { return }

        phase = .downloading(fraction: 0, detail: "Starting…")
        task = Task.detached(priority: .utility) {
            do {
                _ = try await AsrModels.download(version: .v2) { progress in
                    Task { @MainActor in
                        ParakeetDownloadState.shared.apply(progress)
                    }
                }
                mclog("[Parakeet] Background model download complete")
                await MainActor.run { ParakeetDownloadState.shared.finish(error: nil) }
            } catch {
                mclog("[Parakeet] Background model download failed: \(error.localizedDescription)")
                await MainActor.run { ParakeetDownloadState.shared.finish(error: error) }
            }
        }
    }

    /// Clear a failure and try again (the checklist's Retry button).
    func retry() {
        guard case .failed = phase else { return }
        phase = .idle
        startIfNeeded()
    }

    private func apply(_ progress: DownloadProgress) {
        // Ignore late callbacks after completion/failure already landed.
        guard task != nil else { return }
        switch progress.phase {
        case .listing:
            phase = .downloading(fraction: 0, detail: "Preparing…")
        case .downloading(let completed, let total):
            let detail = total > 0 ? "file \(min(completed + 1, total)) of \(total)" : ""
            phase = .downloading(fraction: progress.fractionCompleted, detail: detail)
        case .compiling:
            phase = .compiling
        }
    }

    private func finish(error: Error?) {
        task = nil
        if let error {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .ready
        let callbacks = onReadyOnce
        onReadyOnce = []
        for callback in callbacks { callback() }
    }
}
