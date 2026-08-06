import Accelerate
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

    /// True when the Parakeet model files are already on disk, so loading
    /// needs no network. Mirrors the exact check downloadAndLoad performs
    /// before deciding to fetch. Checked at session start so a fresh install
    /// is never blocked behind the ~600 MB download — it starts on the
    /// SFSpeech fallback instead while the model fetches in the background.
    nonisolated static var isCachedOnDisk: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v2), version: .v2)
    }

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
/// after a silence gap that ends a sentence (see endsSentence) or at the
/// max window length.
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
    /// Tick counter for the partial-refresh throttle; touched only from the
    /// (serial) tick loop.
    private var tickCount = 0
    private let converter = AudioConverter()
    private var lastPartial = ""
    /// Voiced audio arrived after the snapshot behind `lastPartial` — when
    /// false at commit time, `lastPartial` already covers the window and the
    /// commit-time re-transcription can be skipped entirely.
    private var voicedSinceLastPartial = false

    private let voiceFloor: Float
    private let commitSilence: TimeInterval
    private let maxChunkSeconds = 30.0
    private let preRollSamples = 8_000         // 0.5s kept while waiting for voice

    /// Defaults are tuned for the microphone (room noise sets the floor).
    /// System audio is digitally silent between phrases and remote voices
    /// trail off quietly, so its pipeline passes a lower floor and a longer
    /// silence gap — otherwise sentences fragment into 2-3 word chunks that
    /// transcribe with no context.
    init(speaker: String, sessionStart: Date,
         voiceFloor: Float = 0.006, commitSilence: TimeInterval = 0.9) {
        self.speaker = speaker
        self.sessionStart = sessionStart
        self.voiceFloor = voiceFloor
        self.commitSilence = commitSilence
    }

    func start() {
        lock.lock()
        running = true
        lock.unlock()
        // 1s tick: every partial pass costs a fixed 15s-padded encoder run
        // (FluidAudio pads short windows), so cadence is the direct CPU
        // knob. 700ms → 1s cut inference ~30% with no visible partial lag.
        tickTask = Task.detached(priority: .userInitiated) { [weak self] in
            while let self, self.isRunning {
                try? await Task.sleep(for: .seconds(1))
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
        var rms: Float = 0
        converted.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress, !ptr.isEmpty else { return }
            vDSP_rmsqv(base, 1, &rms, vDSP_Length(ptr.count))
        }

        lock.lock()
        if rms > voiceFloor {
            if chunkStartedAt == nil {
                chunkStartedAt = Date().addingTimeInterval(-Double(converted.count) / 16_000)
            }
            lastVoiceAt = Date()
            // Only VOICED audio marks the window dirty. Silent buffers keep
            // appending (they belong in the final transcription) but must not
            // trigger a re-transcribe: each pass costs a full 15s-padded
            // encoder run no matter how little is pending, and the trailing
            // commitSilence gap alone was burning ~3 wasted passes per
            // utterance on the system-audio channel.
            newAudioSinceTick = true
            voicedSinceLastPartial = true
        }
        samples.append(contentsOf: converted)
        if chunkStartedAt == nil {
            // No voice yet: keep only a short pre-roll so the first word
            // isn't clipped but silence doesn't accumulate.
            if samples.count > preRollSamples {
                samples.removeFirst(samples.count - preRollSamples)
            }
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
        tickCount += 1
        let (hasVoice, hasNew, lastVoice, duration) = withLock {
            (chunkStartedAt != nil, newAudioSinceTick, lastVoiceAt, Double(samples.count) / 16_000)
        }
        guard isRunning, hasVoice, duration > 0.3 else { return }

        let silenceFor = lastVoice.map { Date().timeIntervalSince($0) } ?? 0
        // Sentence-aware commit: a silence gap only commits when the window
        // reads as a finished sentence. Remote voices duck under the floor
        // mid-thought (meeting apps noise-gate aggressively), and committing
        // there shredded the far side into 1-3 word chunks that transcribe
        // with no context. A mid-sentence gap instead holds the window open
        // — up to 3× the gap — so the thought re-transcribes as one piece.
        // The window cap still bounds everything.
        if duration > maxChunkSeconds
            || (silenceFor > commitSilence
                && (Self.endsSentence(lastPartial) || silenceFor > commitSilence * 3)) {
            await commit(force: false)
        } else if hasNew {
            // Partial-refresh throttle: every pass re-transcribes the whole
            // window, so cost per pass grows with window age (a 25s window
            // is ~2-3 encoder runs, re-run every tick while the speaker
            // talks). Long windows refresh the on-screen partial every 2nd
            // then 3rd tick instead. Commit checks above still run at every
            // tick, so commit timing — what the transcript and tests see —
            // is unchanged; only mid-monologue partial latency stretches.
            let stride = duration > 22 ? 3 : duration > 12 ? 2 : 1
            guard tickCount % stride == 0 else { return }
            let snapshot = withLock {
                newAudioSinceTick = false
                // Cleared at snapshot time, not after the (slow) transcribe:
                // voice arriving mid-inference re-marks the flag, so a commit
                // never reuses a partial that misses audio.
                voicedSinceLastPartial = false
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

    /// Whether the latest partial looks like a completed sentence. Parakeet
    /// punctuates reliably, so a missing terminator mid-window is strong
    /// evidence the speaker isn't done. Empty partials (no transcription
    /// tick yet) don't count as complete — the 3× silence cap covers them.
    static func endsSentence(_ text: String) -> Bool {
        var trimmed = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = trimmed.last, "\"')]".contains(last) {
            trimmed = trimmed.dropLast()
        }
        guard let last = trimmed.last else { return false }
        return ".!?…".contains(last)
    }

    private func commit(force: Bool) async {
        let (snapshot, started, ended, reusable): ([Float], Date?, Date?, Bool) = withLock {
            guard force || chunkStartedAt != nil else { return ([], nil, nil, false) }
            let snap = samples
            let s = chunkStartedAt
            let e = lastVoiceAt
            let r = !voicedSinceLastPartial
            samples.removeAll(keepingCapacity: true)
            chunkStartedAt = nil
            lastVoiceAt = nil
            newAudioSinceTick = false
            voicedSinceLastPartial = false
            return (snap, s, e, r)
        }
        guard !snapshot.isEmpty else { return }

        let priorPartial = lastPartial
        lastPartial = ""
        onPartial?("")

        // Voice must have been detected: a forced flush of pre-roll silence
        // makes Parakeet hallucinate short filler words ("Okay.").
        guard snapshot.count > 3_200, started != nil else { return }
        let text: String
        if reusable, !priorPartial.isEmpty {
            // No voiced audio since the last partial — the window is what the
            // partial already transcribed, so skip the second full pass. On a
            // typical call this halves commit-path inference.
            text = priorPartial
        } else {
            guard let fresh = await ParakeetEngine.shared.transcribe(snapshot) else { return }
            text = fresh
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let t = max(0, (started ?? Date()).timeIntervalSince(sessionStart))
        let endT = max(t, (ended ?? Date()).timeIntervalSince(sessionStart))
        mclog("[Parakeet:\(speaker)] Commit: \(trimmed.prefix(80))")
        onUtterance?(Utterance(t: t, speaker: speaker, text: trimmed, endT: endT))
    }
}
