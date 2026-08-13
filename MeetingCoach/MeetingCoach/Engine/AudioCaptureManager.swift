import Accelerate
import AVFoundation
import AudioToolbox
import ScreenCaptureKit
import Speech

/// Which audio source a diarization result describes. Labels overlap across
/// channels only by enrolled name, so consumers key relabeling off this.
enum DiarizationChannel: String, Sendable {
    case mic      // mixed room stream (mic-only mode) — splits "Meeting"
    case system   // meeting-app output — splits "Them"
}

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

    /// Immutable per-session language policy. Settings changes never alter a
    /// running capture or its cleanup/decoder behavior.
    let language: ResolvedMeetingLanguage

    /// Called with a new utterance to append.
    var onUtterance: (@Sendable @MainActor (Utterance) -> Void)?

    /// Live in-flight text per speaker for dictation-style display.
    /// Empty text means that speaker's pending line cleared.
    var onPartialText: (@Sendable @MainActor (_ speaker: String, _ text: String) -> Void)?

    /// Finalized diarization segments: who spoke when, session-relative,
    /// per audio channel. The full list is re-published as it grows.
    /// `.system` splits "Them" into individual remote speakers; `.mic`
    /// splits the mixed "Meeting" stream in mic-only mode.
    var onSpeakerSegments: (@Sendable @MainActor (DiarizationChannel, [SpeakerSegment]) -> Void)?
    var onStatus: (@Sendable @MainActor (String) -> Void)?
    /// Fired when the system-audio stream dies mid-session — the session
    /// is mic-only from that point (the arbiter's mic-only protections
    /// must kick in, and echo suppression stands down).
    var onSystemAudioLost: (@Sendable @MainActor () -> Void)?

    /// Vocabulary to bias recognition toward (participant names, deal terms).
    var contextualHints: [String] = []

    /// Post-ASR repair of known-term garbles ("app sumo" → AppSumo), applied
    /// to every commit and partial as it leaves a pipeline — BEFORE the echo
    /// filter, so both channels' text is normalized identically and echo
    /// overlap still matches word-for-word. Lock-guarded: "Fix a misheard
    /// term" swaps in an updated normalizer MID-CALL from the main actor
    /// while the pipeline queues are reading it.
    var vocabulary: VocabularyNormalizer? {
        get { vocabLock.lock(); defer { vocabLock.unlock() }; return _vocabulary }
        set { vocabLock.lock(); _vocabulary = newValue; vocabLock.unlock() }
    }
    private let vocabLock = NSLock()
    private var _vocabulary: VocabularyNormalizer?

    /// Stamped after engine selection, not at init: the non-English path can
    /// block on a multi-hundred-MB download, and the clock must start when
    /// capture actually does.
    private(set) var startTime = Date()
    private var isRunning = false

    // One recognition pipeline per audio source
    private var micPipeline: (any TranscriptionPipeline)?
    private var sysPipeline: (any TranscriptionPipeline)?
    private(set) var transcriptionEngine: TranscriptionEngine = .sfSpeech
    private var usingParakeet: Bool { transcriptionEngine.isParakeet }
    /// Which engine this session actually transcribed with — recorded into
    /// the saved session so accuracy regressions (bench/transcription.sh)
    /// can be attributed to the engine, not guessed at. "SFSpeech" here on
    /// a Parakeet-capable Mac means the session hit the fallback path.
    var engineLabel: String { transcriptionEngine.displayLabel(language: language) }

    // Audio sources
    private var engine: AVAudioEngine?
    private var scStream: SCStream?
    private let sysAudioQueue = DispatchQueue(label: "com.coach.systemAudio")
    private var hasSystemAudio = false

    // Mic device-change recovery. When the default input device changes
    // mid-session — a Continuity phone call handed to this Mac, AirPods
    // connecting, a headset flipping profiles — AVAudioEngine posts a
    // configuration change and STOPS. Without recovery the tap never fires
    // again while the UI keeps saying "Listening". The notification is the
    // primary signal; a watchdog backstops it (a running engine delivers
    // buffers continuously, silence included, so a quiet tap = dead capture).
    private let micRestartQueue = DispatchQueue(label: "com.coach.micRestart")
    private var micWatchdog: DispatchSourceTimer?
    private var micRecovering = false          // micRestartQueue-confined
    private var lastMicBufferAt = Date()       // micStateLock-guarded
    private var micPeakRMS: Float = 0          // micStateLock-guarded
    private var lastRMSLogAt = Date()          // micStateLock-guarded
    private var lastNonzeroAudioAt = Date()    // micStateLock-guarded

    /// True after start() when system audio couldn't be captured (Screen
    /// Recording declined/unavailable) — no structural You/Them separation.
    var isMicOnly: Bool { !hasSystemAudio }

    /// True when this session deliberately skipped system audio because an
    /// Apple call (FaceTime/iPhone relay) was in progress — the UI should
    /// explain the call-audio limitation, not ask for Screen Recording.
    private(set) var isAppleCall = false

    // Speaker diarization. Mic-only mode: split "Meeting" into Speaker 1/2/…
    // Dual mode: split the system-audio "Them" into Them 1/2/… — the mic
    // channel is structurally "You" and needs no diarizer.
    private var diarizer: SpeakerDiarizer?
    private var sysDiarizer: SpeakerDiarizer?

    // Bleed gate: if echo cancellation fails (or is unavailable), the mic
    // picks up the other side through the speakers. Track when the mic was
    // last genuinely hot so bleed-only transcriptions can be dropped.
    private let micStateLock = NSLock()
    private var lastLoudMicAt = Date.distantPast
    private let micSilenceFloor: Float = 0.005
    /// When the far side (system audio) last carried real energy. Bleed can
    /// only exist while the speakers are actually saying something — a mic
    /// utterance with no recent far-side audio is quiet NEAR speech (e.g. a
    /// phone call heard faintly across the desk), not leakage.
    private var lastLoudSystemAt = Date.distantPast
    private let sysLoudFloor: Float = 0.002

    // Software echo suppression: with voice processing off, the far side's
    // voice can reach the mic acoustically (speakers). Mic sentences that
    // mostly repeat concurrent "Them" speech are stripped before delivery.
    private let echoFilter = EchoFilter()

    init(language: ResolvedMeetingLanguage) {
        self.language = language
        super.init()
    }


    // MARK: - Public

    func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        // Engine selection MUST precede startSystemAudio(): the "Them"
        // pipeline is created inside it via makePipeline, which branches on
        // usingParakeet. For months this ran after, so the far side was
        // always transcribed by SFSpeech — a second engine running all
        // session (localspeechrecognition at ~37% CPU) with the 0.10.0
        // far-side thresholds silently discarded.
        //
        // Prefer the Parakeet engine (far more accurate than SFSpeech on
        // meeting audio); fall back to SFSpeech if the model can't load.
        // When the model isn't on disk yet, don't hold the session hostage
        // behind a ~600 MB download: start immediately on SFSpeech (if it can
        // run on-device) and fetch Parakeet in the background for next time.
        let preferredEngine = language.preferredEngine
        if !PlatformSupport.neuralModelsSupported {
            // Intel: Parakeet would SIGFPE the process (see PlatformSupport).
            // SFSpeech is the only engine; if it can't run on-device,
            // makePipeline below throws and the session refuses to start
            // rather than send audio off-device.
            guard language.isEnglish else {
                isRunning = false
                throw CaptureError.multilingualRequiresAppleSilicon(language.englishName)
            }
            transcriptionEngine = .sfSpeech
            mclog("[Capture] Intel Mac — Parakeet unsupported, using SFSpeech")
        } else if let version = preferredEngine.parakeetVersion,
                  ParakeetEngine.isCachedOnDisk(version) {
            emitStatus("Preparing transcription engine...")
            if await ParakeetEngine.shared.ensureLoaded(version: version) {
                transcriptionEngine = preferredEngine
            } else if language.isEnglish
                        && Self.sfSpeechOnDeviceAvailable(for: language.sfSpeechLocaleIdentifier) {
                transcriptionEngine = .sfSpeech
            } else {
                isRunning = false
                throw CaptureError.transcriptionEngineUnavailable(language.englishName)
            }
        } else if language.isEnglish
                    && Self.sfSpeechOnDeviceAvailable(for: language.sfSpeechLocaleIdentifier) {
            transcriptionEngine = .sfSpeech
            Task { @MainActor in
                ParakeetDownloadState.shared.startIfNeeded(for: preferredEngine)
            }
            emitStatus("Higher-accuracy transcription downloading — ready next session")
            mclog("[Capture] Parakeet v2 not cached — starting on SFSpeech, downloading in background")
        } else {
            // Non-English has no SFSpeech escape hatch: starting an English
            // recognizer would silently turn the whole meeting into garbage.
            emitStatus("Downloading \(language.englishName) transcription…")
            let ready = await ParakeetDownloadState.shared.prepare(for: preferredEngine)
            guard !Task.isCancelled else {
                isRunning = false
                throw CancellationError()
            }
            guard ready, let version = preferredEngine.parakeetVersion,
                  await ParakeetEngine.shared.ensureLoaded(version: version) else {
                isRunning = false
                throw CaptureError.transcriptionEngineUnavailable(language.englishName)
            }
            transcriptionEngine = preferredEngine
        }
        startTime = Date()
        mclog("[Capture] Transcription engine: \(engineLabel)")

        // Apple call surfaces (FaceTime, iPhone-relayed calls) render their
        // audio through a privacy-protected call path that ScreenCaptureKit
        // cannot hear: the SCK stream starts fine and delivers digital
        // silence for the far side. Dual mode is then poison — the "Them"
        // pipeline never speaks, the bleed gate never arms (it requires a
        // recently-loud system channel), the echo pool stays empty, and the
        // far side leaking speakers → mic gets transcribed as "You" (Ned's
        // FaceTime read "you talked 100% of the time", field report
        // 2026-08-08). Mic-only is strictly better here: on speakers the
        // room mic hears both sides and the diarizer splits them.
        let appleCallHolders = await (MeetingDetectionService.micUsingBundleIDs() ?? [])
            .intersection(MeetingDetectionService.appleCallBundleIDs)
        if !appleCallHolders.isEmpty {
            isAppleCall = true
            hasSystemAudio = false
            mclog("[Capture] Apple call in progress (\(appleCallHolders.sorted().joined(separator: ", "))) — skipping system audio (SCK can't hear call audio), mic-only + diarizer")
        } else {
            // System audio next — whether it works decides mic configuration
            // (echo cancellation on, mic speaker label "You" vs "Meeting").
            do {
                try await startSystemAudio()
                hasSystemAudio = true
            } catch {
                mclog("[Capture] System audio failed: \(error.localizedDescription)")
                hasSystemAudio = false
            }
        }

        // Mic pipeline. Without system audio there is no You/Them separation,
        // so keep the old generic label.
        //
        // Apple-call mode runs ~10x quieter: once FaceTime flips the device
        // into call mode, other clients get the processed stream at whisper
        // levels (measured live 2026-08-09: peak RMS 0.0063 during normal
        // conversation vs the 0.006 floor — one word survived in 4 minutes).
        // Lower the floor to match what the call path actually delivers.
        emitStatus("Setting up microphone...")
        let micPipe = try makePipeline(speaker: hasSystemAudio ? "You" : "Meeting",
                                       voiceFloor: isAppleCall ? 0.0012 : 0.006)
        micPipeline = micPipe
        micPipe.start()
        do {
            try startMicrophone()
        } catch {
            isRunning = false
            stop()
            throw error
        }

        // Saved voices enroll into whichever diarizer runs, so known people
        // come back by name. Pre-call participant names float their
        // profiles to the front of the enrollment order.
        let profiles = VoiceProfileStore.loadAll(preferring: contextualHints)
        // The whole return path (saved voice → auto-label next session) was
        // undiagnosable from logs — enrollment lines only appear per
        // profile, so an empty store and a failed load looked identical.
        mclog("[Voices] Loaded \(profiles.count) profile(s)"
              + (profiles.isEmpty ? "" : ": \(profiles.map(\.name).joined(separator: ", "))"))

        if hasSystemAudio {
            emitStatus(listeningStatus)
            mclog("[Capture] Dual pipelines active (mic=You, system=Them)")
            // Diarize the far side: "Them" lumps every remote participant
            // together — split it into Them 1/2/… (or enrolled names).
            sysDiarizer = makeDiarizer(labelPrefix: "Them", channel: .system, profiles: profiles)
        } else {
            emitStatus(listeningStatus)
            // Single mixed stream: run on-device diarization so the
            // transcript can distinguish speakers.
            diarizer = makeDiarizer(labelPrefix: "Speaker", channel: .mic, profiles: profiles)
        }
    }

    private func makeDiarizer(labelPrefix: String, channel: DiarizationChannel,
                              profiles: [VoiceProfile]) -> SpeakerDiarizer {
        let dia = SpeakerDiarizer(labelPrefix: labelPrefix, profiles: profiles)
        dia.onSegments = { [weak self] segments in
            guard let self else { return }
            Task { @MainActor [onSpeakerSegments = self.onSpeakerSegments] in
                onSpeakerSegments?(channel, segments)
            }
        }
        dia.start()
        return dia
    }

    /// Route a rename to the diarizer that owns the label. Renames the live
    /// timeline (future turns carry the name) and saves the speaker's
    /// collected voice clip as a profile for future sessions.
    func renameSpeaker(_ label: String, to name: String) {
        for dia in [diarizer, sysDiarizer].compactMap({ $0 }) {
            dia.knows(label) { known in
                if known { dia.rename(label, to: name) }
            }
        }
    }

    func stop() {
        isRunning = false

        // Kill the recovery machinery first so a restart can't race teardown.
        NotificationCenter.default.removeObserver(
            self, name: .AVAudioEngineConfigurationChange, object: nil)
        micWatchdog?.cancel()
        micWatchdog = nil

        // Stop mic — on the restart queue, so an in-flight recovery attempt
        // finishes first and can't resurrect the engine after teardown.
        micRestartQueue.sync {
            micRecovering = false
            engine?.stop()
            engine?.inputNode.removeTap(onBus: 0)
            engine = nil
        }

        // Stop diarization (flushes the final partial chunk). References are
        // kept: renaming a speaker from the post-session view still routes
        // through them to reach the collected voice clips.
        diarizer?.stop()
        sysDiarizer?.stop()

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
            guard let version = transcriptionEngine.parakeetVersion else {
                throw CaptureError.transcriptionEngineUnavailable(language.englishName)
            }
            pipe = ParakeetPipeline(speaker: speaker, sessionStart: startTime,
                                    voiceFloor: voiceFloor, commitSilence: commitSilence,
                                    modelVersion: version,
                                    languageHint: language.parakeetLanguageHint)
        } else {
            let locale = language.sfSpeechLocaleIdentifier
            guard let recognizer = SFSpeechRecognizer(locale: .init(identifier: locale)),
                  recognizer.isAvailable else {
                throw CaptureError.speechNotAvailable(locale)
            }
            // Hard local-first constraint: audio must never route to Apple's
            // servers. Refuse to start rather than silently falling back.
            guard recognizer.supportsOnDeviceRecognition else {
                throw CaptureError.onDeviceUnavailable(locale)
            }
            let sf = RecognitionPipeline(speaker: speaker, recognizer: recognizer, sessionStart: startTime)
            sf.contextualHints = contextualHints
            pipe = sf
        }
        pipe.onUtterance = { [weak self] u in self?.deliver(u) }
        pipe.onPartial = { [weak self] text in
            guard let self else { return }
            let normalized = self.vocabulary?.normalize(text) ?? text
            var display = normalized
            if speaker == "Them" {
                // Feed the echo pool from partials: committed "Them" text can
                // lag the mic commit by many seconds, partials arrive in ~1s.
                self.echoFilter.recordFarPartial(normalized)
            } else if self.hasSystemAudio, !normalized.isEmpty {
                // The live pending line should not show the far side's words.
                display = self.echoFilter.filter(
                    normalized, since: Date().addingTimeInterval(-35))?.text ?? ""
            }
            Task { @MainActor [onPartialText = self.onPartialText] in
                onPartialText?(speaker, display)
            }
        }
        return pipe
    }

    /// Deliver an utterance from a pipeline, applying wake-word and
    /// vocabulary hygiene, then echo suppression and the bleed gate on the
    /// mic side.
    private func deliver(_ u: Utterance) {
        // A phone/HomePod activation leaking into the room is not meeting
        // speech — drop it before it pollutes the transcript or echo pool.
        if WakeWordFilter.isWakeNoise(u.text) {
            mclog("[Capture] Dropped wake-word noise (\(u.speaker)): \(u.text.prefix(30))")
            return
        }
        var u = u
        if let vocabulary {
            u = Utterance(t: u.t, speaker: u.speaker,
                          text: vocabulary.normalize(u.text), endT: u.endT)
        }
        if hasSystemAudio {
            if u.speaker == "Them" {
                // Remember far-side words for echo comparison (partials feed
                // the pool too; commits catch re-transcription revisions).
                echoFilter.recordFarText(u.text)
            } else {
                // Bleed gate backstop: mic has been quiet — whatever was
                // transcribed leaked from the speakers. Only plausible while
                // the speakers were recently loud: with the far side silent
                // there is nothing to leak, and dropping then deletes real
                // (just faint) near speech — a phone call taken on the
                // iPhone across the desk lost every "You" line this way.
                micStateLock.lock()
                let sinceLoud = Date().timeIntervalSince(lastLoudMicAt)
                let sinceSystemLoud = Date().timeIntervalSince(lastLoudSystemAt)
                micStateLock.unlock()
                if sinceLoud > 3.0 && sinceSystemLoud < 6.0 {
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
        try startMicEngine()
        micStateLock.lock()
        lastMicBufferAt = Date()
        micStateLock.unlock()
        observeMicConfigChanges()
        startMicWatchdog()
    }

    private func startMicEngine() throws {
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode

        // A Continuity phone-call handoff makes the iPhone's mic the system
        // DEFAULT input — and that device delivers silence to every app but
        // the call. Capturing it is how a session said "Listening" for 15s
        // over an empty transcript (Noah, 2026-08-05). Pin the Mac's own
        // mic instead: coaching listens to the room, and the built-in mic
        // hears both Noah and a speakerphone call.
        var pinnedInput: AudioDeviceID?
        if let defaultDevice = Self.defaultInputDeviceID(),
           Self.isContinuityCapture(defaultDevice),
           let builtIn = Self.builtInInputDeviceID() {
            pinnedInput = builtIn
            Self.setInputDevice(builtIn, on: inputNode, label: "pre-start")
        }

        // NEVER enable voice processing (Apple's echo cancellation) in
        // normal sessions: it ducks all other system audio — even at the
        // minimum ducking level users could barely hear their Zoom call —
        // and it hijacks the mic into "call mode" (multi-channel formats,
        // Bluetooth quality drops). Acoustic echo (the far side leaking
        // speakers → mic) is handled in software instead: see isLikelyEcho
        // + the bleed gate in deliver().
        //
        // During an Apple call this makes no difference either way: macOS
        // hard-walls the mic from every other client while FaceTime/Phone
        // owns it — plain AUHAL (3ch), VPIO (7ch), rebuild after rebuild,
        // all deliver pure digital zeros (measured live 2026-08-09). The
        // zero-audio watchdog + the call banner are the honest behavior.
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

            self.micStateLock.lock()
            self.lastMicBufferAt = Date()
            self.micStateLock.unlock()

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

            let rms = Self.rmsEnergy(speechBuffer)
            if rms > self.micSilenceFloor {
                self.micStateLock.lock()
                self.lastLoudMicAt = Date()
                self.micStateLock.unlock()
            }
            // Level telemetry (debug builds): peak RMS per 5s window. Field
            // question this answers: during an Apple call, does the shared
            // mic deliver real levels to us, or a call-mode-attenuated
            // whisper below every voice floor? (FaceTime session 2026-08-09
            // transcribed one word in 4 minutes; floors are tuned for
            // rms ≈ 0.006+.)
            self.micStateLock.lock()
            if rms > 0 { self.lastNonzeroAudioAt = Date() }
            self.micPeakRMS = max(self.micPeakRMS, rms)
            if Date().timeIntervalSince(self.lastRMSLogAt) > 5 {
                mclog(String(format: "[Mic] Peak RMS last 5s: %.4f%@",
                             self.micPeakRMS,
                             self.micPeakRMS < 0.006 ? " (below voice floor)" : ""))
                self.micPeakRMS = 0
                self.lastRMSLogAt = Date()
            }
            self.micStateLock.unlock()

            self.micPipeline?.append(speechBuffer)
        }

        try audioEngine.start()
        engine = audioEngine
        mclog("[Mic] Engine started")

        // start() re-resolves the AUHAL's device and can silently undo a
        // pre-start pin (observed 2026-08-05: pin returned noErr, engine
        // came up on the iPhone mic anyway). Read back what the unit is
        // actually capturing and re-assert on the live engine if needed.
        if let pinned = pinnedInput,
           Self.currentInputDevice(of: inputNode) != pinned {
            Self.setInputDevice(pinned, on: inputNode, label: "post-start")
            let now = Self.currentInputDevice(of: inputNode)
            if now != pinned {
                // Last resort: a full stop/start cycle with the device set
                // while the engine is down.
                audioEngine.stop()
                Self.setInputDevice(pinned, on: inputNode, label: "restart")
                try audioEngine.start()
            }
            mclog("[Mic] Capture device after re-pin: \(Self.currentInputDevice(of: inputNode) ?? 0) (wanted \(pinned))")
        }
    }

    private static func setInputDevice(_ device: AudioDeviceID,
                                       on node: AVAudioInputNode, label: String) {
        guard let unit = node.audioUnit else {
            mclog("[Mic] Can't pin input (\(label)): no audio unit")
            return
        }
        var dev = device
        let err = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &dev,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        mclog("[Mic] Pinned built-in mic (\(label), device \(device), err \(err))")
    }

    private static func currentInputDevice(of node: AVAudioInputNode) -> AudioDeviceID? {
        guard let unit = node.audioUnit else { return nil }
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &dev, &size)
        return err == noErr ? dev : nil
    }

    // MARK: - Microphone recovery

    /// The steady-state status line for the active capture mode.
    private var listeningStatus: String {
        if hasSystemAudio { return "Listening (you + them)" }
        return isAppleCall ? "Waiting — macOS blocks apps from hearing this call"
                           : "Listening (mic only — grant Screen Recording for Zoom)"
    }

    // MARK: - Input device selection (CoreAudio)

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return err == noErr && device != 0 ? device : nil
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &type)
        return type
    }

    private static func isContinuityCapture(_ device: AudioDeviceID) -> Bool {
        let transport = transportType(device)
        return transport == kAudioDeviceTransportTypeContinuityCaptureWired
            || transport == kAudioDeviceTransportTypeContinuityCaptureWireless
    }

    /// The Mac's own microphone: first built-in-transport device that has
    /// input channels. nil on a Mac mini with no mic — the pin is skipped
    /// and capture stays on the default device, same as before this fix.
    private static func builtInInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return nil }
        var devices = [AudioDeviceID](repeating: 0,
                                      count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
        else { return nil }

        for device in devices where transportType(device) == kAudioDeviceTransportTypeBuiltIn {
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var configSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &inputAddress, 0, nil, &configSize) == noErr,
                  configSize > 0 else { continue }
            let listPointer = UnsafeMutableRawPointer.allocate(
                byteCount: Int(configSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { listPointer.deallocate() }
            guard AudioObjectGetPropertyData(device, &inputAddress, 0, nil, &configSize,
                                             listPointer) == noErr else { continue }
            let buffers = UnsafeMutableAudioBufferListPointer(
                listPointer.assumingMemoryBound(to: AudioBufferList.self))
            if buffers.reduce(0, { $0 + Int($1.mNumberChannels) }) > 0 { return device }
        }
        return nil
    }

    /// The input device changed or reconfigured under the engine (Continuity
    /// call handoff, AirPods, sample-rate switch). The engine has already
    /// stopped by the time this fires — rebuild capture on the new device.
    private func observeMicConfigChanges() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(micConfigDidChange(_:)),
            name: .AVAudioEngineConfigurationChange, object: nil)
    }

    @objc private func micConfigDidChange(_ note: Notification) {
        guard let posted = note.object as? AVAudioEngine, posted === engine else { return }
        // Pinning the capture device away from the system default makes the
        // engine post a config change for ITSELF — rebuilding on that
        // spiraled into a rebuild storm (every rebuild pins, every pin
        // notifies). If the engine is still delivering on the device we
        // chose, the notification is our own echo: ignore it. A genuinely
        // dead engine is caught here (isRunning false) or by the buffer
        // watchdog either way.
        if posted.isRunning {
            mclog("[Mic] Config change but engine still running (device \(Self.currentInputDevice(of: posted.inputNode) ?? 0)) — ignoring")
            return
        }
        mclog("[Mic] Input configuration changed — rebuilding capture")
        restartMicrophone(reason: "config change")
    }

    /// Backstop for changes that never post the notification: a running
    /// engine delivers buffers continuously (silence included), so a tap
    /// that has gone quiet means capture is dead.
    private func startMicWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: micRestartQueue)
        timer.schedule(deadline: .now() + 5, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning, !self.micRecovering else { return }
            self.micStateLock.lock()
            let quiet = Date().timeIntervalSince(self.lastMicBufferAt)
            let zeroFor = Date().timeIntervalSince(self.lastNonzeroAudioAt)
            self.micStateLock.unlock()
            if quiet > 5 {
                mclog("[Mic] No buffers for \(String(format: "%.1f", quiet))s — rebuilding capture")
                self.micRecovering = true
                self.attemptMicRestart(reason: "tap went silent", attempt: 0)
            } else if zeroFor > 8 {
                // Zombie stream: buffers arrive but every sample is digital
                // zero (a live room never reads exactly 0 — only a muted or
                // call-captured device does). Seen live 2026-08-09, twice:
                // the pre-answer 3ch device zeros out for ~23s when a
                // FaceTime call connects, and a call ANSWERED MID-SESSION
                // zeros the mic with no config-change notification at all —
                // the ordinary watchdog stays happy throughout. Check who
                // holds the mic now: if an Apple call grabbed it, adopt
                // call mode (quieter voice floor) before rebuilding.
                mclog("[Mic] Buffers flowing but all-zero for \(String(format: "%.1f", zeroFor))s — rebuilding capture")
                self.micRecovering = true
                Task { @MainActor in
                    let holders = (MeetingDetectionService.micUsingBundleIDs() ?? [])
                        .intersection(MeetingDetectionService.appleCallBundleIDs)
                    self.micRestartQueue.async {
                        guard self.isRunning else { self.micRecovering = false; return }
                        if !holders.isEmpty { self.adoptAppleCallMode(holders: holders) }
                        self.attemptMicRestart(reason: "zero-audio zombie", attempt: 0)
                    }
                }
            }
        }
        timer.resume()
        micWatchdog = timer
    }

    /// micRestartQueue only. A call was answered mid-session: the mic just
    /// went digitally silent and an Apple call daemon now holds it. Flip
    /// this session's mic handling to call mode — the call path delivers
    /// ~10x quieter audio, so the pipeline must be rebuilt with the call
    /// voice floor or everything gates out as silence. Mic-only sessions
    /// only: converting a dual (SCK) session mid-flight is a bigger swap,
    /// and every observed case is mic-only by then anyway.
    private func adoptAppleCallMode(holders: Set<String>) {
        guard !isAppleCall, !hasSystemAudio else { return }
        isAppleCall = true
        mclog("[Capture] Apple call grabbed the mic mid-session (\(holders.sorted().joined(separator: ", "))) — adopting call mode")
        if let old = micPipeline,
           let fresh = try? makePipeline(speaker: "Meeting", voiceFloor: 0.0012) {
            old.stop()          // flushes the pending tail
            fresh.start()
            micPipeline = fresh
        }
        emitStatus(listeningStatus)
    }

    private func restartMicrophone(reason: String) {
        micRestartQueue.async { [self] in
            guard !micRecovering else { return }
            micRecovering = true
            attemptMicRestart(reason: reason, attempt: 0)
        }
    }

    /// micRestartQueue only. Tears down the dead engine and brings capture
    /// back on whatever input device is current. The pipeline stays put —
    /// it takes the new device's format per buffer (Parakeet resamples,
    /// SFSpeech reads each buffer's format) — so no transcript state is
    /// lost across the swap.
    private func attemptMicRestart(reason: String, attempt: Int) {
        guard isRunning else { micRecovering = false; return }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        micStateLock.lock()
        let gap = Date().timeIntervalSince(lastMicBufferAt)
        micStateLock.unlock()
        do {
            try startMicEngine()
            // The mic diarizer's clock is fed-audio-relative (see the tap
            // comment) — backfill the dead stretch with silence so segments
            // after the recovery stay aligned to session time.
            if let dia = diarizer, gap > 0.5 {
                dia.enqueue([Float](repeating: 0, count: Int(gap * 16_000)), sampleRate: 16_000)
            }
            micStateLock.lock()
            lastMicBufferAt = Date()
            lastNonzeroAudioAt = Date()   // fresh grace window for the zero-audio check
            micStateLock.unlock()
            micRecovering = false
            mclog("[Mic] Capture restarted (\(reason)) after \(attempt + 1) attempt(s)")
            emitStatus(listeningStatus)
        } catch {
            // A device handoff can hold the mic for a few seconds mid-
            // transition. Retry forever with capped backoff: capture comes
            // back by itself whenever an input device does.
            mclog("[Mic] Restart attempt \(attempt + 1) failed (\(reason)): \(error.localizedDescription)")
            if attempt == 2 { emitStatus("Microphone lost — reconnecting…") }
            let delay = min(5.0, Double(attempt) + 1)
            micRestartQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.attemptMicRestart(reason: reason, attempt: attempt + 1)
            }
        }
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
    private static func sfSpeechOnDeviceAvailable(for locale: String) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: .init(identifier: locale)),
              recognizer.isAvailable else { return false }
        return recognizer.supportsOnDeviceRecognition
    }

    private func emitStatus(_ msg: String) {
        Task { @MainActor [onStatus] in
            onStatus?(msg)
        }
    }

    /// RMS energy of a PCM buffer (vDSP — this runs per buffer on the
    /// audio tap path, a hand-rolled loop is measurable CPU there)
    private static func rmsEnergy(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(count))
        return rms
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
        if Self.rmsEnergy(pcmBuffer) > sysLoudFloor {
            micStateLock.lock()
            lastLoudSystemAt = Date()
            micStateLock.unlock()
        }
        // Mirror the mono stream into the far-side diarizer (config pins
        // this stream to 1 channel). Fed unconditionally: its timestamps
        // are relative to fed audio, so gaps would skew every segment.
        if let dia = sysDiarizer, let ch = pcmBuffer.floatChannelData?[0] {
            let samples = Array(UnsafeBufferPointer(start: ch, count: Int(pcmBuffer.frameLength)))
            dia.enqueue(samples, sampleRate: pcmBuffer.format.sampleRate)
        }
        sysPipeline?.append(pcmBuffer)
    }
}

@available(macOS 14.2, *)
extension AudioCaptureManager: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        mclog("[Capture] System audio stream stopped: \(error.localizedDescription)")
        // The session is genuinely mic-only from here: without this,
        // isMicOnly stayed false, so the arbiter kept the dual-mode 45s
        // end cap (losing mic-only's unlimited veto) and the echo filter
        // kept second-guessing mic utterances against a dead channel.
        hasSystemAudio = false
        emitStatus("System audio lost — mic only")
        Task { @MainActor [onSystemAudioLost] in
            onSystemAudioLost?()
        }
    }
}

// MARK: - Errors

enum CaptureError: Error, LocalizedError {
    case speechNotAvailable(String)
    case speechNotAuthorized
    case onDeviceUnavailable(String)
    case multilingualRequiresAppleSilicon(String)
    case transcriptionEngineUnavailable(String)
    case systemAudioFailed(String)
    case microphoneNotAvailable(String)

    var errorDescription: String? {
        switch self {
        case .speechNotAvailable(let locale): "Speech recognition is not available for \(locale). Enable Dictation in System Settings > Keyboard."
        case .speechNotAuthorized: "Speech recognition not authorized. Check System Settings > Privacy > Speech Recognition."
        case .onDeviceUnavailable(let locale): "On-device speech recognition is not available for \(locale). Refusing to start: audio must never leave this Mac. Download the English dictation model in System Settings > Keyboard > Dictation."
        case .multilingualRequiresAppleSilicon(let language): "\(language) transcription requires an Apple Silicon Mac. Intel Macs support English through Apple's on-device transcription."
        case .transcriptionEngineUnavailable(let language): "The on-device \(language) transcription engine isn't ready. Check its download in Settings → General, then retry."
        case .systemAudioFailed(let msg): msg
        case .microphoneNotAvailable(let msg): msg
        }
    }
}
