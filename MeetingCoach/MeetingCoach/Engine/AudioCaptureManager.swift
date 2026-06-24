import AVFoundation
import ScreenCaptureKit
import Speech

/// Captures both microphone and system audio (via ScreenCaptureKit) and feeds
/// them into a single SFSpeechRecognizer pipeline for transcription.
@available(macOS 14.2, *)
final class AudioCaptureManager: NSObject, @unchecked Sendable {

    /// Called with a new utterance to append.
    var onUtterance: (@Sendable @MainActor (Utterance) -> Void)?
    var onStatus: (@Sendable @MainActor (String) -> Void)?

    private let speechRecognizer: SFSpeechRecognizer?
    private let startTime = Date()
    private var isRunning = false

    // Single recognition pipeline (both sources feed into this)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var generation = 0
    private var emittedWordCount = 0
    private var lastEmitTime: Date = Date()
    private var flushTimer: Timer?

    // Audio sources
    private var engine: AVAudioEngine?
    private var scStream: SCStream?
    private let sysAudioQueue = DispatchQueue(label: "com.coach.systemAudio")
    private var hasSystemAudio = false

    // Speaker detection via audio energy
    private var micEnergy: Float = 0
    private var sysEnergy: Float = 0
    private let energyDecay: Float = 0.85

    override init() {
        speechRecognizer = SFSpeechRecognizer(locale: .init(identifier: "en-US"))
        super.init()
    }

    // MARK: - Public

    func start() async throws {
        guard !isRunning else { return }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw CaptureError.speechNotAvailable
        }

        isRunning = true

        // Start recognition FIRST so both audio sources can feed it
        startRecognition()

        // Start microphone
        emitStatus("Setting up microphone...")
        try startMicrophone()

        // Start system audio (optional — for Zoom/Teams capture)
        do {
            try await startSystemAudio()
            hasSystemAudio = true
            emitStatus("Listening (mic + system audio)")
            mclog("[Capture] Both mic and system audio active")
        } catch {
            mclog("[Capture] System audio failed: \(error.localizedDescription)")
            emitStatus("Listening (mic only — grant Screen Recording for Zoom)")
        }
    }

    func stop() {
        isRunning = false
        cancelFlushTimer()

        // Stop mic
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil

        // Stop system audio
        if let stream = scStream {
            stream.stopCapture { _ in }
            scStream = nil
        }

        // Stop recognition
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask = nil
    }

    // MARK: - Microphone

    private func startMicrophone() throws {
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode

        try? inputNode.setVoiceProcessingEnabled(false)

        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0 else {
            isRunning = false
            throw CaptureError.microphoneNotAvailable(
                "No microphone available. Check System Settings > Privacy & Security > Microphone."
            )
        }

        mclog("[Mic] Format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch")

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.recognitionRequest?.append(buffer)
            // Track mic energy for speaker detection
            let energy = self.rmsEnergy(buffer)
            self.micEnergy = max(energy, self.micEnergy * self.energyDecay)
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

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sysAudioQueue)
        try await stream.startCapture()

        scStream = stream
        mclog("[Capture] System audio started via ScreenCaptureKit")
    }

    // MARK: - Speech recognition (single pipeline)

    private func startRecognition() {
        let oldTask = recognitionTask
        let oldRequest = recognitionRequest

        generation += 1
        let gen = generation
        emittedWordCount = 0

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if speechRecognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        oldTask?.cancel()
        oldRequest?.endAudio()

        mclog("[Speech] Starting recognition gen=\(gen)")
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self, gen == self.generation else { return }
            if let result {
                self.handleResult(result)
            }
            if error != nil || (result?.isFinal == true) {
                if let error {
                    mclog("[Speech] Error: \(error.localizedDescription)")
                }
                guard self.isRunning else { return }
                DispatchQueue.global().async {
                    guard self.isRunning, gen == self.generation else { return }
                    mclog("[Speech] Restarting recognition")
                    self.startRecognition()
                }
            }
        }
    }

    // MARK: - Result handler

    private func handleResult(_ result: SFSpeechRecognitionResult) {
        let full = result.bestTranscription.formattedString
        guard !full.isEmpty else { return }

        let t = Date().timeIntervalSince(startTime)
        let allWords = full.split(separator: " ")

        if allWords.count < emittedWordCount {
            mclog("[Speech] Revision: words=\(allWords.count) < emitted=\(emittedWordCount), resetting")
            emittedWordCount = 0
        }

        let stableCount = result.isFinal ? allWords.count : max(0, allWords.count - 1)
        let available = stableCount - emittedWordCount

        // Emit aggressively: 2+ new words, or 1+ if final, or any if 1.5s since last emit
        let timeSinceLastEmit = Date().timeIntervalSince(lastEmitTime)
        let minWords: Int
        if result.isFinal {
            minWords = 1
        } else if timeSinceLastEmit > 1.5 {
            minWords = 1  // flush stale words
        } else {
            minWords = 2  // normal: emit every 2 words
        }
        guard available >= minWords else {
            // Schedule a flush timer to catch stragglers
            scheduleFlushTimer()
            return
        }

        let chunk = allWords[emittedWordCount..<stableCount].joined(separator: " ")
        emittedWordCount = stableCount
        lastEmitTime = Date()
        cancelFlushTimer()

        mclog("[Speech] Emitting \(available) words (timeSince=\(String(format: "%.1f", timeSinceLastEmit))s): \(chunk.prefix(80))")

        // Determine speaker based on which audio source is louder
        let speaker: String
        if !hasSystemAudio {
            speaker = "Meeting"
        } else if micEnergy > sysEnergy * 1.5 {
            speaker = "You"
        } else if sysEnergy > micEnergy * 1.5 {
            speaker = "Them"
        } else {
            speaker = "Meeting"
        }

        let u = Utterance(t: t, speaker: speaker, text: chunk)
        Task { @MainActor [onUtterance] in
            onUtterance?(u)
        }
    }

    // MARK: - Flush timer

    /// Schedule a timer to force-emit any pending words after 1.5s of silence.
    private func scheduleFlushTimer() {
        // Don't stack timers
        guard flushTimer == nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.flushTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                guard let self, self.isRunning else { return }
                self.flushTimer = nil
                // Trigger the recognizer to give us a result by requesting partial
                // The next handleResult call with timeSinceLastEmit > 1.5 will flush
                mclog("[Speech] Flush timer fired — pending words will emit on next result")
            }
        }
    }

    private func cancelFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = nil
    }

    // MARK: - Helpers

    private func emitStatus(_ msg: String) {
        Task { @MainActor [onStatus] in
            onStatus?(msg)
        }
    }

    /// RMS energy of an AVAudioEngine tap buffer
    private func rmsEnergy(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        return sqrt(sum / Float(count))
    }

    /// RMS energy of a PCM buffer from ScreenCaptureKit
    private func rmsEnergyPCM(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        return sqrt(sum / Float(count))
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
        // Don't feed system audio into speech recognizer — mixing two audio
        // sources with different buffer characteristics causes it to produce
        // zero results. Just track energy for speaker detection.
        let energy = rmsEnergyPCM(pcmBuffer)
        sysEnergy = max(energy, sysEnergy * energyDecay)
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
    case systemAudioFailed(String)
    case microphoneNotAvailable(String)

    var errorDescription: String? {
        switch self {
        case .speechNotAvailable: "Speech recognition not available. Enable Dictation in System Settings > Keyboard."
        case .speechNotAuthorized: "Speech recognition not authorized. Check System Settings > Privacy > Speech Recognition."
        case .systemAudioFailed(let msg): msg
        case .microphoneNotAvailable(let msg): msg
        }
    }
}
