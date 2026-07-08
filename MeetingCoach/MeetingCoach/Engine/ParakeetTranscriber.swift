import AVFoundation
import FluidAudio
import Foundation

/// Shared Parakeet ASR engine (FluidAudio, on-device CoreML).
///
/// Benchmarked against SFSpeechRecognizer on identical 77s meeting audio:
/// Apple's on-device engine dropped the first 60 seconds and mangled domain
/// terms ("rev share" → "Risha"); Parakeet v2 was near-verbatim. One model
/// instance serves both pipelines; transcribe calls are actor-serialized.
actor ParakeetEngine {
    static let shared = ParakeetEngine()

    private var manager: AsrManager?

    /// Load the engine, downloading models on first run (~600 MB, cached in
    /// Application Support/FluidAudio). Returns false if unavailable — the
    /// caller falls back to SFSpeechRecognizer.
    func ensureLoaded() async -> Bool {
        if manager != nil { return true }
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v2)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            manager = m
            mclog("[Parakeet] Engine ready")
            return true
        } catch {
            mclog("[Parakeet] Engine unavailable: \(error.localizedDescription)")
            return false
        }
    }

    /// Transcribe 16 kHz mono samples. Fresh decoder state per call — each
    /// call re-reads one growing utterance window, not a continuation.
    func transcribe(_ samples: [Float]) async -> String? {
        guard let manager else { return nil }
        do {
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(samples, decoderState: &state)
            return result.text
        } catch {
            mclog("[Parakeet] transcribe failed: \(error.localizedDescription)")
            return nil
        }
    }
}

/// One Parakeet transcription pipeline for one audio source, mirroring
/// RecognitionPipeline's interface. Buffers the current utterance and
/// re-transcribes the whole window ~every 0.7s (RTF ~120x makes this cheap):
/// partial results stream to the UI, and the window commits as an Utterance
/// after a silence gap or at the max window length.
final class ParakeetPipeline: TranscriptionPipeline, @unchecked Sendable {
    let speaker: String
    var onUtterance: ((Utterance) -> Void)?
    var onPartial: ((String) -> Void)?

    private let sessionStart: Date
    private let lock = NSLock()
    private var samples: [Float] = []          // 16k mono, uncommitted window
    private var chunkStartedAt: Date?          // wall clock of first voice
    private var lastVoiceAt: Date?
    private var newAudioSinceTick = false
    private var running = false
    private var tickTask: Task<Void, Never>?
    private let converter = AudioConverter()
    private var lastPartial = ""

    private let voiceFloor: Float = 0.006
    private let commitSilence: TimeInterval = 0.9
    private let maxChunkSeconds = 30.0
    private let preRollSamples = 8_000         // 0.5s kept while waiting for voice

    init(speaker: String, sessionStart: Date) {
        self.speaker = speaker
        self.sessionStart = sessionStart
    }

    func start() {
        lock.lock()
        running = true
        lock.unlock()
        tickTask = Task.detached(priority: .userInitiated) { [weak self] in
            while let self, self.isRunning {
                try? await Task.sleep(for: .milliseconds(700))
                await self.tick()
            }
        }
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        tickTask?.cancel()
        tickTask = nil
        // Flush whatever is pending so the transcript tail isn't lost.
        // Strong capture on purpose: the capture manager drops its reference
        // right after stop() returns, and a weak self would let the pipeline
        // deallocate before this flush ever runs.
        Task { [self] in
            await commit(force: true)
        }
    }

    /// Append audio from the tap/stream thread. Any format — resampled here.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let converted = try? converter.resampleBuffer(buffer) else { return }
        var sum: Float = 0
        for s in converted { sum += s * s }
        let rms = converted.isEmpty ? 0 : (sum / Float(converted.count)).squareRoot()

        lock.lock()
        if rms > voiceFloor {
            if chunkStartedAt == nil {
                chunkStartedAt = Date().addingTimeInterval(-Double(converted.count) / 16_000)
            }
            lastVoiceAt = Date()
        }
        samples.append(contentsOf: converted)
        if chunkStartedAt == nil {
            // No voice yet: keep only a short pre-roll so the first word
            // isn't clipped but silence doesn't accumulate.
            if samples.count > preRollSamples {
                samples.removeFirst(samples.count - preRollSamples)
            }
        } else {
            newAudioSinceTick = true
        }
        lock.unlock()
    }

    private var isRunning: Bool {
        withLock { running }
    }

    /// Synchronous scoped locking — safe to call from async contexts.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func tick() async {
        let (hasVoice, hasNew, lastVoice, duration) = withLock {
            (chunkStartedAt != nil, newAudioSinceTick, lastVoiceAt, Double(samples.count) / 16_000)
        }
        guard isRunning, hasVoice, duration > 0.3 else { return }

        let silenceFor = lastVoice.map { Date().timeIntervalSince($0) } ?? 0
        if silenceFor > commitSilence || duration > maxChunkSeconds {
            await commit(force: false)
        } else if hasNew {
            let snapshot = withLock {
                newAudioSinceTick = false
                return samples
            }
            guard let text = await ParakeetEngine.shared.transcribe(snapshot) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isRunning, !trimmed.isEmpty, trimmed != lastPartial {
                lastPartial = trimmed
                onPartial?(trimmed)
            }
        }
    }

    private func commit(force: Bool) async {
        let (snapshot, started, ended): ([Float], Date?, Date?) = withLock {
            guard force || chunkStartedAt != nil else { return ([], nil, nil) }
            let snap = samples
            let s = chunkStartedAt
            let e = lastVoiceAt
            samples.removeAll(keepingCapacity: true)
            chunkStartedAt = nil
            lastVoiceAt = nil
            newAudioSinceTick = false
            return (snap, s, e)
        }
        guard !snapshot.isEmpty else { return }

        lastPartial = ""
        onPartial?("")

        guard snapshot.count > 3_200, started != nil || force else { return }
        guard let text = await ParakeetEngine.shared.transcribe(snapshot) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let t = max(0, (started ?? Date()).timeIntervalSince(sessionStart))
        let endT = max(t, (ended ?? Date()).timeIntervalSince(sessionStart))
        mclog("[Parakeet:\(speaker)] Commit: \(trimmed.prefix(80))")
        onUtterance?(Utterance(t: t, speaker: speaker, text: trimmed, endT: endT))
    }
}
