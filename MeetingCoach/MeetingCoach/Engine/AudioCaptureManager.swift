import AVFoundation
import ScreenCaptureKit
import Speech

/// One transcription pipeline for one audio source, whatever the engine.
protocol TranscriptionPipeline: AnyObject {
    var onUtterance: ((Utterance) -> Void)? { get set }
    var onPartial: ((String) -> Void)? { get set }
    func start()
    func stop()
    func append(_ buffer: AVAudioPCMBuffer)
}

/// Captures microphone and system audio (via ScreenCaptureKit) and feeds each
/// source into its OWN speech-recognition pipeline. Speaker identity is
/// structural — mic = "You", system audio = "Them" — instead of inferred from
/// audio energy heuristics.
///
/// Echo cancellation (voice processing) is enabled on the mic when system
/// audio capture is active, so the other side's voice coming out of the
/// speakers does not bleed into the "You" pipeline. A time-based bleed gate
/// backstops the case where echo cancellation is unavailable.
@available(macOS 14.2, *)
final class AudioCaptureManager: NSObject, @unchecked Sendable {

    /// Called with a new utterance to append.
    var onUtterance: (@Sendable @MainActor (Utterance) -> Void)?

    /// Live in-flight text per speaker for dictation-style display.
    /// Empty text means that speaker's pending line cleared.
    var onPartialText: (@Sendable @MainActor (_ speaker: String, _ text: String) -> Void)?

    /// Finalized diarization segments (mic-only mode): who spoke when,
    /// session-relative. The full list is re-published as it grows.
    var onSpeakerSegments: (@Sendable @MainActor ([SpeakerSegment]) -> Void)?
    var onStatus: (@Sendable @MainActor (String) -> Void)?

    /// Vocabulary to bias recognition toward (participant names, deal terms).
    var contextualHints: [String] = []

    private let startTime = Date()
    private var isRunning = false

    // One recognition pipeline per audio source
    private var micPipeline: (any TranscriptionPipeline)?
    private var sysPipeline: (any TranscriptionPipeline)?
    private var usingParakeet = false
    /// Which engine this session actually transcribed with — recorded into
    /// the saved session so accuracy regressions (bench/transcription.sh)
    /// can be attributed to the engine, not guessed at. "SFSpeech" here on
    /// a Parakeet-capable Mac means the session hit the fallback path.
    private(set) var engineLabel = "unknown"

    // Audio sources
    private var engine: AVAudioEngine?
    private var scStream: SCStream?
    private let sysAudioQueue = DispatchQueue(label: "com.coach.systemAudio")
    private var hasSystemAudio = false

    /// True after start() when system audio couldn't be captured (Screen
    /// Recording declined/unavailable) — no structural You/Them separation.
    var isMicOnly: Bool { !hasSystemAudio }

    // Speaker diarization (mic-only mode: split "Meeting" into Speaker 1/2/…)
    private var diarizer: SpeakerDiarizer?

    // Bleed gate: if echo cancellation fails (or is unavailable), the mic
    // picks up the other side through the speakers. Track when the mic was
    // last genuinely hot so bleed-only transcriptions can be dropped.
    private let micStateLock = NSLock()
    private var lastLoudMicAt = Date.distantPast
    private let micSilenceFloor: Float = 0.005

    // Software echo suppression: with voice processing off, the far side's
    // voice can reach the mic acoustically (speakers). Mic sentences that
    // mostly repeat concurrent "Them" speech are stripped before delivery.
    private let echoFilter = EchoFilter()


    // MARK: - Public

    func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        // System audio first — whether it works decides mic configuration
        // (echo cancellation on, mic speaker label "You" vs "Meeting").
        do {
            try await startSystemAudio()
            hasSystemAudio = true
        } catch {
            mclog("[Capture] System audio failed: \(error.localizedDescription)")
            hasSystemAudio = false
        }

        // Prefer the Parakeet engine (far more accurate than SFSpeech on
        // meeting audio); fall back to SFSpeech if the model can't load.
        // When the model isn't on disk yet, don't hold the session hostage
        // behind a ~600 MB download: start immediately on SFSpeech (if it can
        // run on-device) and fetch Parakeet in the background for next time.
        if ParakeetEngine.isCachedOnDisk || !Self.sfSpeechOnDeviceAvailable {
            emitStatus("Preparing transcription engine...")
            usingParakeet = await ParakeetEngine.shared.ensureLoaded()
        } else {
            usingParakeet = false
            ParakeetEngine.prefetchInBackground()
            emitStatus("Higher-accuracy transcription downloading — ready next session")
            mclog("[Capture] Parakeet not cached — starting on SFSpeech, downloading in background")
        }
        engineLabel = usingParakeet ? "Parakeet" : "SFSpeech"
        mclog("[Capture] Transcription engine: \(engineLabel)")

        // Mic pipeline. Without system audio there is no You/Them separation,
        // so keep the old generic label.
        emitStatus("Setting up microphone...")
        let micPipe = try makePipeline(speaker: hasSystemAudio ? "You" : "Meeting")
        micPipeline = micPipe
        micPipe.start()
        do {
            try startMicrophone()
        } catch {
            isRunning = false
            stop()
            throw error
        }

        if hasSystemAudio {
            emitStatus("Listening (you + them)")
            mclog("[Capture] Dual pipelines active (mic=You, system=Them)")
        } else {
            emitStatus("Listening (mic only — grant Screen Recording for Zoom)")
            // Single mixed stream: run on-device diarization so the
            // transcript can distinguish speakers.
            let dia = SpeakerDiarizer()
            dia.onSegments = { [weak self] segments in
                guard let self else { return }
                Task { @MainActor [onSpeakerSegments = self.onSpeakerSegments] in
                    onSpeakerSegments?(segments)
                }
            }
            dia.start()
            diarizer = dia
        }
    }

    func stop() {
        isRunning = false

        // Stop mic
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil

        // Stop diarization (flushes the final partial chunk)
        diarizer?.stop()
        diarizer = nil

        // Stop system audio
        if let stream = scStream {
            stream.stopCapture { _ in }
            scStream = nil
        }

        // Stop recognition (flushes any pending tail first)
        micPipeline?.stop()
        micPipeline = nil
        sysPipeline?.stop()
        sysPipeline = nil
    }

    // MARK: - Pipelines

    private func makePipeline(speaker: String,
                              voiceFloor: Float = 0.006,
                              commitSilence: TimeInterval = 0.9) throws -> any TranscriptionPipeline {
        let pipe: any TranscriptionPipeline
        if usingParakeet {
            pipe = ParakeetPipeline(speaker: speaker, sessionStart: startTime,
                                    voiceFloor: voiceFloor, commitSilence: commitSilence)
        } else {
            guard let recognizer = SFSpeechRecognizer(locale: .init(identifier: "en-US")),
                  recognizer.isAvailable else {
                throw CaptureError.speechNotAvailable
            }
            // Hard local-first constraint: audio must never route to Apple's
            // servers. Refuse to start rather than silently falling back.
            guard recognizer.supportsOnDeviceRecognition else {
                throw CaptureError.onDeviceUnavailable
            }
            let sf = RecognitionPipeline(speaker: speaker, recognizer: recognizer, sessionStart: startTime)
            sf.contextualHints = contextualHints
            pipe = sf
        }
        pipe.onUtterance = { [weak self] u in self?.deliver(u) }
        pipe.onPartial = { [weak self] text in
            guard let self else { return }
            var display = text
            if speaker == "Them" {
                // Feed the echo pool from partials: committed "Them" text can
                // lag the mic commit by many seconds, partials arrive in ~1s.
                self.echoFilter.recordFarPartial(text)
            } else if self.hasSystemAudio, !text.isEmpty {
                // The live pending line should not show the far side's words.
                display = self.echoFilter.filter(
                    text, since: Date().addingTimeInterval(-35))?.text ?? ""
            }
            Task { @MainActor [onPartialText = self.onPartialText] in
                onPartialText?(speaker, display)
            }
        }
        return pipe
    }

    /// Deliver an utterance from a pipeline, applying echo suppression and
    /// the bleed gate to the mic side.
    private func deliver(_ u: Utterance) {
        var u = u
        if hasSystemAudio {
            if u.speaker == "Them" {
                // Remember far-side words for echo comparison (partials feed
                // the pool too; commits catch re-transcription revisions).
                echoFilter.recordFarText(u.text)
            } else {
                // Bleed gate backstop: mic has been quiet — whatever was
                // transcribed leaked from the speakers.
                micStateLock.lock()
                let sinceLoud = Date().timeIntervalSince(lastLoudMicAt)
                micStateLock.unlock()
                if sinceLoud > 3.0 {
                    mclog("[Capture] Dropped bleed chunk (mic quiet \(String(format: "%.1f", sinceLoud))s): \(u.text.prefix(50))")
                    return
                }
                // Strip echoed sentences. The pool window opens slightly
                // before the chunk started: echo is simultaneous with the
                // far speech that caused it.
                let chunkStart = startTime.addingTimeInterval(u.t - 3)
                guard let (text, keptFraction) = echoFilter.filter(u.text, since: chunkStart) else {
                    mclog("[Capture] Dropped echo chunk: \(u.text.prefix(50))")
                    return
                }
                if keptFraction < 1.0 {
                    mclog("[Capture] Stripped echo (kept \(Int(keptFraction * 100))%): \(text.prefix(50))")
                    // Shrink the span too, or talk-time would credit "You"
                    // for the time the far side was speaking into the mic.
                    u = Utterance(t: u.t, speaker: u.speaker, text: text,
                                  endT: u.t + u.duration * keptFraction)
                }
            }
        }
        Task { @MainActor [onUtterance] in
            onUtterance?(u)
        }
    }

    // MARK: - Microphone

    private func startMicrophone() throws {
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode

        // NEVER enable voice processing (Apple's echo cancellation): it ducks
        // all other system audio — even at the minimum ducking level users
        // could barely hear their Zoom call — and it hijacks the mic into
        // "call mode" (multi-channel formats, Bluetooth quality drops).
        // Acoustic echo (the far side leaking speakers → mic) is handled in
        // software instead: see isLikelyEcho + the bleed gate in deliver().
        try? inputNode.setVoiceProcessingEnabled(false)

        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0 else {
            throw CaptureError.microphoneNotAvailable(
                "No microphone available. Check System Settings > Privacy & Security > Microphone."
            )
        }

        mclog("[Mic] Format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch")

        // Voice processing exposes multi-channel formats on some devices
        // (7ch observed) and SFSpeechRecognizer rejects those buffers
        // outright — the request dies instantly with "No speech detected".
        // Downmix to mono before anything reaches the recognizer.
        var converter: AVAudioConverter?
        var monoFormat: AVAudioFormat?
        if recordingFormat.channelCount > 1,
           let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: recordingFormat.sampleRate,
                                    channels: 1, interleaved: false) {
            converter = AVAudioConverter(from: recordingFormat, to: mono)
            monoFormat = mono
            mclog("[Mic] Downmixing \(recordingFormat.channelCount)ch → mono for speech")
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self else { return }

            var speechBuffer = buffer
            if let converter, let monoFormat,
               let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) {
                var fed = false
                var convErr: NSError?
                converter.convert(to: mono, error: &convErr) { _, outStatus in
                    if fed { outStatus.pointee = .noDataNow; return nil }
                    fed = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                guard convErr == nil else { return }
                speechBuffer = mono
            }
            // Mirror the mono stream into the diarizer (mic-only mode).
            // Fed unconditionally: its timestamps are relative to fed audio,
            // so gaps would skew every segment after them.
            if let dia = self.diarizer, let ch = speechBuffer.floatChannelData?[0] {
                let samples = Array(UnsafeBufferPointer(start: ch, count: Int(speechBuffer.frameLength)))
                dia.enqueue(samples, sampleRate: speechBuffer.format.sampleRate)
            }

            if Self.rmsEnergy(speechBuffer) > self.micSilenceFloor {
                self.micStateLock.lock()
                self.lastLoudMicAt = Date()
                self.micStateLock.unlock()
            }

            self.micPipeline?.append(speechBuffer)
        }

        try audioEngine.start()
        engine = audioEngine
        mclog("[Mic] Engine started")
    }

    // MARK: - System audio (ScreenCaptureKit)

    private func startSystemAudio() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            throw CaptureError.systemAudioFailed("No display found")
        }

        let selfBundleID = Bundle.main.bundleIdentifier ?? ""
        let excludedApps = content.applications.filter { $0.bundleIdentifier == selfBundleID }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1

        // Minimize video overhead
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        // System audio is digitally silent between phrases (Zoom/Meet noise-
        // gate the remote stream) and remote voices trail off well below the
        // mic's room-noise floor. With mic-tuned thresholds this channel
        // fragmented into 2-3 word chunks (median 3 words over a real 82-min
        // call) that transcribe with no context and clip boundary words —
        // hence the lower floor and the longer silence gap here.
        let pipe = try makePipeline(speaker: "Them", voiceFloor: 0.002, commitSilence: 2.0)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sysAudioQueue)
        try await stream.startCapture()

        sysPipeline = pipe
        pipe.start()
        scStream = stream
        mclog("[Capture] System audio started via ScreenCaptureKit")
    }

    // MARK: - Helpers

    /// Whether the SFSpeech fallback can honor the never-leaves-the-Mac
    /// constraint. If it can't, session start waits for Parakeet instead.
    private static var sfSpeechOnDeviceAvailable: Bool {
        guard let recognizer = SFSpeechRecognizer(locale: .init(identifier: "en-US")),
              recognizer.isAvailable else { return false }
        return recognizer.supportsOnDeviceRecognition
    }

    private func emitStatus(_ msg: String) {
        Task { @MainActor [onStatus] in
            onStatus?(msg)
        }
    }

    /// RMS energy of a PCM buffer
    private static func rmsEnergy(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        return sqrt(sum / Float(count))
    }
}

// MARK: - Recognition pipeline

/// One speech-recognition pipeline for one audio source. All mutable state is
/// confined to `queue`; `append` is safe from any thread.
@available(macOS 14.2, *)
private final class RecognitionPipeline: TranscriptionPipeline, @unchecked Sendable {
    let speaker: String
    /// Called on the pipeline's queue with each emitted utterance.
    var onUtterance: ((Utterance) -> Void)?

    /// Vocabulary bias applied to every recognition request.
    var contextualHints: [String] = []

    /// In-flight recognizer text not yet emitted as an utterance. Fires on
    /// every partial result so the UI can render live, dictation-style;
    /// empty string means the pending line was committed or cleared.
    var onPartial: ((String) -> Void)?

    private let recognizer: SFSpeechRecognizer
    private let sessionStart: Date
    private let queue: DispatchQueue

    // `request` is the only state touched off-queue (audio threads append to
    // it), so guard the pointer with a lock.
    private let requestLock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var genStart = Date()
    private var pendingStartedAt: Date?
    private var running = false

    private var latestWords: [String] = []
    private var latestSegments: [SegmentTiming] = []

    /// Sendable snapshot of the only segment fields we use. The Speech types
    /// (SFSpeechRecognitionResult, SFTranscriptionSegment) are not Sendable on
    /// pre-26 SDKs, so they must not cross the recognition-callback → queue
    /// boundary; extract values first.
    struct SegmentTiming: Sendable {
        let timestamp: TimeInterval
        let duration: TimeInterval
    }
    private var emittedWordCount = 0
    private var lastEmitTime = Date()
    private var flushTimer: DispatchSourceTimer?

    /// Force-emit any pending tail after this much recognizer silence.
    private let flushDelay: TimeInterval = 1.2

    init(speaker: String, recognizer: SFSpeechRecognizer, sessionStart: Date) {
        self.speaker = speaker
        self.recognizer = recognizer
        self.sessionStart = sessionStart
        self.queue = DispatchQueue(label: "com.coach.pipeline.\(speaker.lowercased())")
    }

    func start() {
        queue.async {
            self.running = true
            self.startRecognition()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.cancelFlushTimer()
            // Flush pending words so the transcript tail isn't lost.
            self.emit(upTo: self.latestWords.count, reason: "stop")
            self.task?.cancel()
            self.currentRequest?.endAudio()
            self.setRequest(nil)
            self.task = nil
            self.onPartial?("")
        }
    }

    /// Append audio. Safe from any thread (mic tap / SCStream queue).
    func append(_ buffer: AVAudioPCMBuffer) {
        currentRequest?.append(buffer)
    }

    // MARK: - Request pointer (lock-guarded)

    private var currentRequest: SFSpeechAudioBufferRecognitionRequest? {
        requestLock.lock()
        defer { requestLock.unlock() }
        return request
    }

    private func setRequest(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        requestLock.lock()
        request = r
        requestLock.unlock()
    }

    // MARK: - Recognition (on queue)

    private func startRecognition() {
        generation += 1
        let gen = generation
        genStart = Date()
        emittedWordCount = 0
        latestWords = []
        latestSegments = []

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.requiresOnDeviceRecognition = true
        req.contextualStrings = contextualHints

        task?.cancel()
        currentRequest?.endAudio()
        setRequest(req)

        mclog("[Speech:\(speaker)] Starting recognition gen=\(gen)")
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            // Snapshot Sendable values here: the Speech result objects must
            // not be captured by the queue closure (not Sendable pre-26 SDK).
            let transcript = result?.bestTranscription.formattedString
            let segments = result?.bestTranscription.segments.map {
                SegmentTiming(timestamp: $0.timestamp, duration: $0.duration)
            } ?? []
            let isFinal = result?.isFinal == true
            let errorDescription = error?.localizedDescription
            self.queue.async {
                guard gen == self.generation, self.running else { return }
                if let transcript {
                    self.handleResult(transcript: transcript, segments: segments, isFinal: isFinal)
                }
                if errorDescription != nil || isFinal {
                    if let errorDescription {
                        mclog("[Speech:\(self.speaker)] Error: \(errorDescription)")
                    }
                    // A generation that dies within seconds means the source is
                    // broken (no audio, bad format) — back off instead of
                    // hot-looping thousands of restarts at full CPU.
                    let lifetime = Date().timeIntervalSince(self.genStart)
                    if lifetime < 2 {
                        mclog("[Speech:\(self.speaker)] Restarting recognition (backing off 1s)")
                        self.queue.asyncAfter(deadline: .now() + 1) {
                            guard gen == self.generation, self.running else { return }
                            self.startRecognition()
                        }
                    } else {
                        mclog("[Speech:\(self.speaker)] Restarting recognition")
                        self.startRecognition()
                    }
                }
            }
        }
    }

    private func handleResult(transcript: String, segments: [SegmentTiming], isFinal: Bool) {
        guard !transcript.isEmpty else { return }

        let words = transcript.split(separator: " ").map(String.init)

        // Revision: the recognizer replaced already-emitted words. Move the
        // pointer back; don't re-emit (the old text was already shown).
        if words.count < emittedWordCount {
            mclog("[Speech:\(speaker)] Revision: words=\(words.count) < emitted=\(emittedWordCount)")
            emittedWordCount = words.count
        }
        latestWords = words
        latestSegments = segments

        // Wall-clock anchor: the pending chunk began when its first
        // not-yet-emitted word appeared. Recognizer segment timestamps are
        // unreliable in partial results, so this is the timing source.
        if words.count > emittedWordCount, pendingStartedAt == nil {
            pendingStartedAt = Date()
        }

        // Live pending line: everything past the last emit, unstable tail
        // included. The UI shows this immediately; emits below only govern
        // when text is committed to the coach/transcript history.
        onPartial?(words[emittedWordCount...].joined(separator: " "))

        let stableCount = isFinal ? words.count : max(0, words.count - 1)
        let available = stableCount - emittedWordCount
        let sinceEmit = Date().timeIntervalSince(lastEmitTime)

        // Chunks no longer serve speaker detection (identity is structural),
        // so emit small — nudge-relevant words reach the signals sooner.
        let minWords: Int
        if isFinal {
            minWords = 1
        } else if sinceEmit > 2.0 {
            minWords = 3
        } else {
            minWords = 8
        }

        if available >= minWords {
            emit(upTo: stableCount, reason: isFinal ? "final" : "partial")
        } else if words.count > emittedWordCount {
            scheduleFlush()
        }
    }

    private func emit(upTo count: Int, reason: String) {
        let count = min(count, latestWords.count)
        guard count > emittedWordCount else { return }

        let text = latestWords[emittedWordCount..<count].joined(separator: " ")

        // Timing: wall-clock window of the pending chunk. Recognizer segment
        // timestamps looked usable but are ~0 in partial results, which broke
        // every downstream consumer that needed real times (diarization).
        // The chunk spans first-new-word arrival → now, shifted back by
        // typical recognition latency.
        let recognitionLatency: TimeInterval = 0.4
        let now = Date().timeIntervalSince(sessionStart)
        let started = (pendingStartedAt ?? Date()).timeIntervalSince(sessionStart)
        let t = max(0, min(started - recognitionLatency, now))
        let endT = max(t, now - recognitionLatency)
        pendingStartedAt = nil

        emittedWordCount = count
        lastEmitTime = Date()
        cancelFlushTimer()

        mclog("[Speech:\(speaker)] Emit (\(reason)): \(text.prefix(80))")
        onUtterance?(Utterance(t: t, speaker: speaker, text: text, endT: endT))
        onPartial?(latestWords[emittedWordCount...].joined(separator: " "))
    }

    // MARK: - Flush (on queue)

    /// Emit the pending tail — including the unstable last word — after the
    /// recognizer goes quiet. The words right before a pause are often the
    /// most coaching-relevant ("so are we agreed?" → silence).
    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + flushDelay)
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            self.flushTimer = nil
            self.emit(upTo: self.latestWords.count, reason: "flush")
        }
        timer.resume()
        flushTimer = timer
    }

    private func cancelFlushTimer() {
        flushTimer?.cancel()
        flushTimer = nil
    }
}

// MARK: - ScreenCaptureKit delegates

@available(macOS 14.2, *)
extension AudioCaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        guard let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.pointee.mSampleRate,
            channels: AVAudioChannelCount(asbd.pointee.mChannelsPerFrame),
            interleaved: false
        ) else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )

        guard status == noErr else { return }
        sysPipeline?.append(pcmBuffer)
    }
}

@available(macOS 14.2, *)
extension AudioCaptureManager: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        mclog("[Capture] System audio stream stopped: \(error.localizedDescription)")
        emitStatus("System audio lost — mic only")
    }
}

// MARK: - Errors

enum CaptureError: Error, LocalizedError {
    case speechNotAvailable
    case speechNotAuthorized
    case onDeviceUnavailable
    case systemAudioFailed(String)
    case microphoneNotAvailable(String)

    var errorDescription: String? {
        switch self {
        case .speechNotAvailable: "Speech recognition not available. Enable Dictation in System Settings > Keyboard."
        case .speechNotAuthorized: "Speech recognition not authorized. Check System Settings > Privacy > Speech Recognition."
        case .onDeviceUnavailable: "On-device speech recognition is not available for en-US. Refusing to start: audio must never leave this Mac. Download the English dictation model in System Settings > Keyboard > Dictation."
        case .systemAudioFailed(let msg): msg
        case .microphoneNotAvailable(let msg): msg
        }
    }
}
