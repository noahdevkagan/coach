import FluidAudio
import Foundation
import Observation

extension TranscriptionEngine {
    var parakeetVersion: AsrModelVersion? {
        switch self {
        case .parakeetV2: .v2
        case .parakeetV3: .v3
        case .sfSpeech: nil
        }
    }
}

extension ResolvedMeetingLanguage {
    var parakeetLanguageHint: Language? {
        guard preferredEngine == .parakeetV3 else { return nil }
        return Language(rawValue: code)
    }
}

/// Observable, serialized download state for both Parakeet engines. Only one
/// multi-hundred-MB transfer runs at a time; requests for the other version
/// queue and coalesce. Cached models complete synchronously.
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
    private(set) var activeEngine: TranscriptionEngine?
    private(set) var failedEngine: TranscriptionEngine?
    private(set) var failureMessages: [TranscriptionEngine: String] = [:]

    /// A waiter on an engine becoming available. `prepare`'s continuation
    /// must resolve exactly once, so it fails fast; `startIfNeeded`'s
    /// fire-when-ready chain instead survives a failed download, so a
    /// successful Retry still fires it (the promised retry-then-fire).
    private struct Completion {
        let survivesFailure: Bool
        let run: @MainActor (Bool) -> Void
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pendingEngines: [TranscriptionEngine] = []
    @ObservationIgnored private var completions:
        [TranscriptionEngine: [Completion]] = [:]

    func isReady(for engine: TranscriptionEngine) -> Bool {
        guard let version = engine.parakeetVersion else { return true }
        return ParakeetEngine.isCachedOnDisk(version)
    }

    func isActive(for engine: TranscriptionEngine) -> Bool {
        activeEngine == engine
    }

    func isPending(for engine: TranscriptionEngine) -> Bool {
        pendingEngines.contains(engine)
    }

    func failureMessage(for engine: TranscriptionEngine) -> String? {
        failureMessages[engine]
    }

    /// Fire-and-forget launch/settings path. The callback fires only after the
    /// requested version is available, including when it had to wait behind
    /// the other version.
    func startIfNeeded(for engine: TranscriptionEngine,
                       onReady: (@MainActor () -> Void)? = nil) {
        let completion = onReady.map { onReady in
            Completion(survivesFailure: true) { success in
                if success { onReady() }
            }
        }
        enqueue(engine, completion: completion, coalescePassiveRequests: true)
    }

    /// Session-start path. Non-English capture awaits v3 rather than falling
    /// through to an English recognizer and producing a garbage transcript.
    func prepare(for engine: TranscriptionEngine) async -> Bool {
        if isReady(for: engine) { return true }
        return await withCheckedContinuation { continuation in
            enqueue(engine,
                    completion: Completion(survivesFailure: false) { success in
                        continuation.resume(returning: success)
                    },
                    coalescePassiveRequests: false)
        }
    }

    func retry(for engine: TranscriptionEngine? = nil) {
        let target = engine ?? failedEngine
        guard let target else { return }
        failedEngine = nil
        failureMessages.removeValue(forKey: target)
        phase = .idle
        enqueue(target, completion: nil, coalescePassiveRequests: false)
    }

    private func enqueue(_ engine: TranscriptionEngine,
                         completion: Completion?,
                         coalescePassiveRequests: Bool) {
        guard PlatformSupport.neuralModelsSupported,
              let version = engine.parakeetVersion else {
            completion?.run(false)
            return
        }
        if ParakeetEngine.isCachedOnDisk(version) {
            if task == nil { phase = .ready }
            // Waiters that survived an earlier failure resolve here too —
            // a Retry (which enqueues with no completion of its own) may
            // find the model already cached.
            let callbacks = completions.removeValue(forKey: engine) ?? []
            callbacks.forEach { $0.run(true) }
            completion?.run(true)
            return
        }
        if let completion { completions[engine, default: []].append(completion) }
        if coalescePassiveRequests {
            // Settings prefetch follows the latest selection. A rapid
            // English → Spanish → English change while v2 is active must not
            // download v3 afterward just because it was briefly selected.
            // Never remove a queued engine with a session-start waiter or an
            // on-ready continuation attached to it.
            pendingEngines.removeAll { queued in
                queued != engine && (completions[queued]?.isEmpty ?? true)
            }
        }
        if activeEngine == engine || pendingEngines.contains(engine) { return }
        guard task == nil else {
            pendingEngines.append(engine)
            return
        }
        begin(engine)
    }

    private func begin(_ engine: TranscriptionEngine) {
        guard let version = engine.parakeetVersion else { return }
        activeEngine = engine
        failedEngine = nil
        failureMessages.removeValue(forKey: engine)
        phase = .downloading(fraction: 0, detail: "Starting…")
        task = Task.detached(priority: .utility) {
            do {
                _ = try await AsrModels.download(version: version) { progress in
                    Task { @MainActor in
                        ParakeetDownloadState.shared.apply(progress, for: engine)
                    }
                }
                mclog("[Parakeet] Background \(engine.rawValue) download complete")
                await MainActor.run {
                    ParakeetDownloadState.shared.finish(engine, error: nil)
                }
            } catch {
                mclog("[Parakeet] Background \(engine.rawValue) download failed: \(error.localizedDescription)")
                await MainActor.run {
                    ParakeetDownloadState.shared.finish(engine, error: error)
                }
            }
        }
    }

    private func apply(_ progress: DownloadProgress, for engine: TranscriptionEngine) {
        guard task != nil, activeEngine == engine else { return }
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

    private func finish(_ engine: TranscriptionEngine, error: Error?) {
        guard activeEngine == engine else { return }
        task = nil
        activeEngine = nil
        let callbacks = completions.removeValue(forKey: engine) ?? []
        if let error {
            failedEngine = engine
            failureMessages[engine] = error.localizedDescription
            phase = .failed(error.localizedDescription)
            // Fail-fast waiters (prepare) resolve now; retry-surviving ones
            // (the launch chain's onReady) stay registered so a successful
            // Retry still fires them.
            let survivors = callbacks.filter(\.survivesFailure)
            if !survivors.isEmpty { completions[engine] = survivors }
            callbacks.filter { !$0.survivesFailure }.forEach { $0.run(false) }
        } else {
            phase = .ready
            callbacks.forEach { $0.run(true) }
        }
        startNextQueuedDownload()
    }

    private func startNextQueuedDownload() {
        while !pendingEngines.isEmpty {
            let next = pendingEngines.removeFirst()
            guard let version = next.parakeetVersion else { continue }
            if ParakeetEngine.isCachedOnDisk(version) {
                let callbacks = completions.removeValue(forKey: next) ?? []
                callbacks.forEach { $0.run(true) }
                continue
            }
            begin(next)
            return
        }
    }
}
