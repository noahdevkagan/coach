import AVFoundation
import ScreenCaptureKit
import Speech

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
    var onStatus: (@Sendable @MainActor (String) -> Void)?

    private let startTime = Date()
    private var isRunning = false

    // One recognition pipeline per audio source
    private var micPipeline: RecognitionPipeline?
    private var sysPipeline: RecognitionPipeline?

    // Audio sources
    private var engine: AVAudioEngine?
    private var scStream: SCStream?
    private let sysAudioQueue = DispatchQueue(label: "com.coach.systemAudio")
    private var hasSystemAudio = false

    // Bleed gate: if echo cancellation fails (or is unavailable), the mic
    // picks up the other side through the speakers. Track when the mic was
    // last genuinely hot so bleed-only transcriptions can be dropped.
    private let micStateLock = NSLock()
    private var lastLoudMicAt = Date.distantPast
    private let micSilenceFloor: Float = 0.005

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

        // Mic pipeline. Without system audio there is no You/Them separation,
        // so keep the old generic label.
        emitStatus("Setting up microphone...")
        let micPipe = try makePipeline(speaker: hasSystemAudio ? "You" : "Meeting")
        micPipeline = micPipe
        micPipe.start()
        do {
            try startMicrophone(echoCancellation: hasSystemAudio)
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
        }
    }

    func stop() {
        isRunning = false

        // Stop mic
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil

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

    private func makePipeline(speaker: String) throws -> RecognitionPipeline {
        guard let recognizer = SFSpeechRecognizer(locale: .init(identifier: "en-US")),
              recognizer.isAvailable else {
            throw CaptureError.speechNotAvailable
        }
        // Hard local-first constraint: audio must never route to Apple's
        // servers. Refuse to start rather than silently falling back.
        guard recognizer.supportsOnDeviceRecognition else {
            throw CaptureError.onDeviceUnavailable
        }
        let pipe = RecognitionPipeline(speaker: speaker, recognizer: recognizer, sessionStart: startTime)
        pipe.onUtterance = { [weak self] u in self?.deliver(u) }
        return pipe
    }

    /// Deliver an utterance from a pipeline, applying the bleed gate.
    private func deliver(_ u: Utterance) {
        // Bleed gate for the mic pipeline: a chunk transcribed while the mic
        // has been silent is the other side leaking through the speakers.
        if hasSystemAudio && u.speaker != "Them" {
            micStateLock.lock()
            let sinceLoud = Date().timeIntervalSince(lastLoudMicAt)
            micStateLock.unlock()
            if sinceLoud > 3.0 {
                mclog("[Capture] Dropped bleed chunk (mic quiet \(String(format: "%.1f", sinceLoud))s): \(u.text.prefix(50))")
                return
            }
        }
        Task { @MainActor [onUtterance] in
            onUtterance?(u)
        }
    }

    // MARK: - Microphone

    private func startMicrophone(echoCancellation: Bool) throws {
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode

        if echoCancellation {
            // Apple's AEC removes system-audio playback from the mic signal,
            // so the "You" pipeline hears only the user.
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                mclog("[Mic] Echo cancellation ON")
            } catch {
                mclog("[Mic] Voice processing unavailable (\(error.localizedDescription)) — relying on bleed gate")
            }
        } else {
            try? inputNode.setVoiceProcessingEnabled(false)
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0 else {
            throw CaptureError.microphoneNotAvailable(
                "No microphone available. Check System Settings > Privacy & Security > Microphone."
            )
        }

        mclog("[Mic] Format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch")

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.micPipeline?.append(buffer)

            if Self.rmsEnergy(buffer) > self.micSilenceFloor {
                self.micStateLock.lock()
                self.lastLoudMicAt = Date()
                self.micStateLock.unlock()
            }
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

        let pipe = try makePipeline(speaker: "Them")

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sysAudioQueue)
        try await stream.startCapture()

        sysPipeline = pipe
        pipe.start()
        scStream = stream
        mclog("[Capture] System audio started via ScreenCaptureKit")
    }

    // MARK: - Helpers

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
private final class RecognitionPipeline: @unchecked Sendable {
    let speaker: String
    /// Called on the pipeline's queue with each emitted utterance.
    var onUtterance: ((Utterance) -> Void)?

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
    private var running = false

    private var latestWords: [String] = []
    private var latestSegments: [SFTranscriptionSegment] = []
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

        task?.cancel()
        currentRequest?.endAudio()
        setRequest(req)

        mclog("[Speech:\(speaker)] Starting recognition gen=\(gen)")
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation, self.running else { return }
                if let result {
                    self.handleResult(result)
                }
                if error != nil || result?.isFinal == true {
                    if let error {
                        mclog("[Speech:\(self.speaker)] Error: \(error.localizedDescription)")
                    }
                    mclog("[Speech:\(self.speaker)] Restarting recognition")
                    self.startRecognition()
                }
            }
        }
    }

    private func handleResult(_ result: SFSpeechRecognitionResult) {
        let full = result.bestTranscription.formattedString
        guard !full.isEmpty else { return }

        let words = full.split(separator: " ").map(String.init)

        // Revision: the recognizer replaced already-emitted words. Move the
        // pointer back; don't re-emit (the old text was already shown).
        if words.count < emittedWordCount {
            mclog("[Speech:\(speaker)] Revision: words=\(words.count) < emitted=\(emittedWordCount)")
            emittedWordCount = words.count
        }
        latestWords = words
        latestSegments = result.bestTranscription.segments

        let stableCount = result.isFinal ? words.count : max(0, words.count - 1)
        let available = stableCount - emittedWordCount
        let sinceEmit = Date().timeIntervalSince(lastEmitTime)

        // Chunks no longer serve speaker detection (identity is structural),
        // so emit small — nudge-relevant words reach the signals sooner.
        let minWords: Int
        if result.isFinal {
            minWords = 1
        } else if sinceEmit > 2.0 {
            minWords = 3
        } else {
            minWords = 8
        }

        if available >= minWords {
            emit(upTo: stableCount, reason: result.isFinal ? "final" : "partial")
        } else if words.count > emittedWordCount {
            scheduleFlush()
        }
    }

    private func emit(upTo count: Int, reason: String) {
        let count = min(count, latestWords.count)
        guard count > emittedWordCount else { return }

        let text = latestWords[emittedWordCount..<count].joined(separator: " ")

        // Timing: prefer recognizer segment timestamps (relative to this
        // generation's audio start); fall back to wall clock.
        let now = Date().timeIntervalSince(sessionStart)
        var t = now
        var endT = now
        if latestSegments.count == latestWords.count, count <= latestSegments.count {
            let first = latestSegments[emittedWordCount]
            let last = latestSegments[count - 1]
            if last.timestamp > 0 {
                let offset = genStart.timeIntervalSince(sessionStart)
                t = offset + first.timestamp
                endT = offset + last.timestamp + last.duration
            }
        }

        emittedWordCount = count
        lastEmitTime = Date()
        cancelFlushTimer()

        mclog("[Speech:\(speaker)] Emit (\(reason)): \(text.prefix(80))")
        onUtterance?(Utterance(t: t, speaker: speaker, text: text, endT: endT))
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
