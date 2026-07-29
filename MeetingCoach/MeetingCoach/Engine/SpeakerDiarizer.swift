import Accelerate
import Foundation
import FluidAudio

/// One finalized "who spoke when" span, session-relative seconds.
struct SpeakerSegment: Sendable {
    let speaker: String
    let start: TimeInterval
    let end: TimeInterval
}

/// On-device streaming speaker diarization (FluidAudio LS-EEND, CoreML).
///
/// Feed it mono buffers from one audio source; it periodically publishes the
/// full finalized segment list so that source's utterances can be relabeled
/// per speaker ("Them 1/2/…" on the system-audio channel, "Speaker 1/2/…"
/// on a mixed mic stream). Everything runs locally — the CoreML model is
/// downloaded once to Application Support/FluidAudio.
///
/// Saved voice profiles are enrolled before any session audio reaches the
/// model, so known voices come back with their real names instead of slot
/// labels. While the session runs, a short clip of each distinct speaker is
/// collected from the finalized segments — naming a speaker saves that clip
/// as their profile for every future session.
/// Streaming FIR decimator (windowed-sinc low-pass + downsample via
/// vDSP_desamp). Capture hands us 48kHz mono but the LS-EEND model runs at
/// 16kHz — decimating once at the boundary cuts ring/preload/clip memory
/// and the model's internal resampling work by the factor, at identical
/// quality. Integer factors only; other rates pass through untouched.
private struct Decimator {
    let factor: Int
    private let filter: [Float]
    /// Tail of the previous buffer, so the FIR window never sees a seam.
    private var carry: [Float] = []

    init?(inputRate: Double, targetRate: Double) {
        guard inputRate > targetRate,
              inputRate.truncatingRemainder(dividingBy: targetRate) == 0 else { return nil }
        factor = Int(inputRate / targetRate)
        // 31-tap Hamming-windowed sinc, cutoff at 0.9× the new Nyquist.
        let taps = 31
        let m = Double(taps - 1)
        let fc = 0.45 / Double(factor)
        var h = [Double](repeating: 0, count: taps)
        for n in 0..<taps {
            let x = Double(n) - m / 2
            let sinc = x == 0 ? 2 * fc : sin(2 * .pi * fc * x) / (.pi * x)
            h[n] = sinc * (0.54 - 0.46 * cos(2 * .pi * Double(n) / m))
        }
        let gain = h.reduce(0, +)
        filter = h.map { Float($0 / gain) }
    }

    mutating func process(_ samples: [Float]) -> [Float] {
        let input = carry + samples
        let taps = filter.count
        guard input.count >= taps else {
            carry = input
            return []
        }
        let outCount = (input.count - taps) / factor + 1
        var out = [Float](repeating: 0, count: outCount)
        vDSP_desamp(input, vDSP_Stride(factor), filter, &out,
                    vDSP_Length(outCount), vDSP_Length(taps))
        carry = Array(input[(outCount * factor)...])
        return out
    }
}

final class SpeakerDiarizer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.coach.diarizer", qos: .utility)
    private var diarizer: LSEENDDiarizer?
    /// Audio arriving before the model finishes loading, so segment
    /// timestamps stay aligned with the session start. Capped below.
    private var preload: [(samples: [Float], rate: Double)] = []
    private var preloadSamples = 0
    private let preloadCap = 16_000 * 60 * 5  // ~5 min at 16kHz (post-decimation)
    private var lastProcess = Date.distantPast
    /// Seconds between inference passes. Chunks accumulate regardless, so a
    /// longer beat batches the same compute into fewer CoreML calls — the
    /// only cost is labels landing a beat later, and relabeling is
    /// retroactive anyway.
    private let processInterval: TimeInterval = 2.0
    private var stopped = false

    /// 48kHz → 16kHz before anything is stored or fed (see Decimator).
    /// Built lazily off the first buffer's rate; nil = pass through.
    private var decimator: Decimator?
    private var decimatorBuilt = false
    private let modelRate: Double = 16_000

    /// Slot labels for unnamed speakers: "\(labelPrefix) \(index + 1)".
    private let labelPrefix: String
    /// Saved voices to enroll once the model is ready.
    private let profiles: [VoiceProfile]

    // MARK: Voice-clip capture (all on `queue`)

    /// Rolling window of recent session audio, session-relative seconds.
    /// Only needs to cover segment-finalization latency, not the session.
    private var ring: [(start: TimeInterval, rate: Double, samples: [Float])] = []
    private var fedSeconds: TimeInterval = 0
    private let ringSeconds: TimeInterval = 45

    private struct ClipBuffer {
        var samples: [Float] = []
        var rate: Double = 0
        /// Segment time already harvested into `samples`.
        var consumedUntil: TimeInterval = 0
    }
    private var clips: [Int: ClipBuffer] = [:]
    /// Display label per slot at last publish — lets rename/clip lookups
    /// keep working after stop() releases the model.
    private var labelBySlot: [Int: String] = [:]
    /// Fingerprint of the last published finalized-segment set. Most ticks
    /// finalize nothing new; skipping those publishes saves the consumer's
    /// full-transcript relabel pass.
    private var publishedCount = -1
    private var publishedLastEnd: Float = -1

    var onSegments: (@Sendable ([SpeakerSegment]) -> Void)?

    init(labelPrefix: String = "Speaker", profiles: [VoiceProfile] = []) {
        self.labelPrefix = labelPrefix
        self.profiles = profiles
    }

    func start() {
        Task {
            do {
                // .dihard3: in-the-wild conversations — right for room audio
                // (in-person meetings, phone-on-speaker near the Mac) and
                // holds up on compressed meeting-app streams.
                let d = try await LSEENDDiarizer(variant: .dihard3)
                self.queue.async {
                    guard !self.stopped else { return }
                    self.enroll(into: d)
                    self.diarizer = d
                    for chunk in self.preload {
                        try? d.addAudio(chunk.samples, sourceSampleRate: chunk.rate)
                    }
                    self.preload = []
                    mclog("[Diarizer:\(self.labelPrefix)] Ready (LS-EEND dihard3)")
                }
            } catch {
                mclog("[Diarizer:\(self.labelPrefix)] Unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// Enqueue mono float samples from the source tap. Safe from any thread.
    func enqueue(_ samples: [Float], sampleRate: Double) {
        queue.async {
            guard !self.stopped else { return }
            var samples = samples
            var rate = sampleRate
            if !self.decimatorBuilt {
                self.decimator = Decimator(inputRate: sampleRate, targetRate: self.modelRate)
                self.decimatorBuilt = true
            }
            if self.decimator != nil {
                samples = self.decimator!.process(samples)
                rate = self.modelRate
                guard !samples.isEmpty else { return }  // FIR warm-up
            }
            self.ringAppend(samples, rate: rate)
            guard let d = self.diarizer else {
                if self.preloadSamples < self.preloadCap {
                    self.preload.append((samples, rate))
                    self.preloadSamples += samples.count
                }
                return
            }
            do {
                try d.addAudio(samples, sourceSampleRate: rate)
            } catch {
                mclog("[Diarizer:\(self.labelPrefix)] addAudio failed: \(error)")
                return
            }

            // Throttle inference + timeline reads.
            guard Date().timeIntervalSince(self.lastProcess) > self.processInterval else { return }
            self.lastProcess = Date()
            do {
                _ = try d.process()
            } catch {
                mclog("[Diarizer:\(self.labelPrefix)] process failed: \(error)")
            }
            self.publish(from: d)
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            if let d = self.diarizer {
                try? d.finalizeSession()
                self.publish(from: d)
            }
            // Keep clips + labelBySlot: naming a speaker from the
            // post-session view still needs them.
            self.diarizer = nil
            self.preload = []
            self.ring = []
        }
    }

    /// Rename the speaker currently displayed as `label`. Renames the live
    /// timeline slot (future publishes carry the name), saves the collected
    /// voice clip as a profile for future sessions, and republishes so the
    /// whole transcript relabels. Works after stop() for the profile part.
    func rename(_ label: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        queue.async {
            guard let slot = self.labelBySlot.first(where: { $0.value == label })?.key
                    ?? self.slotFromLabel(label) else {
                mclog("[Diarizer:\(self.labelPrefix)] rename: unknown label \(label)")
                return
            }
            if let clip = self.clips[slot], clip.rate > 0 {
                VoiceProfileStore.save(name: name, samples: clip.samples, sampleRate: clip.rate)
            } else {
                mclog("[Diarizer:\(self.labelPrefix)] rename: no clip collected for \(label) yet")
            }
            self.labelBySlot[slot] = name
            if let d = self.diarizer {
                _ = d.timeline.upsertSpeaker(named: name, atIndex: slot)
                self.publishedCount = -1   // force: same segments, new labels
                self.publish(from: d)
            }
        }
    }

    /// Whether this diarizer has ever published `label` (so a rename can be
    /// routed to the right channel's diarizer).
    func knows(_ label: String, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            completion(self.labelBySlot.values.contains(label) || self.slotFromLabel(label) != nil)
        }
    }

    // MARK: - Enrollment (on queue)

    /// Feed each saved voice through the model before session audio so known
    /// people surface by name. One slot is always left free for a stranger.
    private func enroll(into d: LSEENDDiarizer) {
        guard !profiles.isEmpty else { return }
        let capacity = max(1, (d.numSpeakers ?? 4) - 1)
        for p in profiles.prefix(capacity) {
            do {
                if let speaker = try d.enrollSpeaker(withAudio: p.samples,
                                                     sourceSampleRate: p.sampleRate,
                                                     named: p.name) {
                    labelBySlot[speaker.index] = p.name
                    mclog("[Diarizer:\(labelPrefix)] Enrolled \(p.name) at slot \(speaker.index)")
                } else {
                    mclog("[Diarizer:\(labelPrefix)] Enrollment produced no speaker for \(p.name)")
                }
            } catch {
                mclog("[Diarizer:\(labelPrefix)] Enroll \(p.name) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Publish + clip harvest (on queue)

    private func publish(from d: LSEENDDiarizer) {
        // Cheap no-change check before any array building.
        var count = 0
        var lastEnd: Float = -1
        for (_, speaker) in d.timeline.speakers {
            count += speaker.finalizedSegmentCount
            if let end = speaker.finalizedSegments.last?.endTime {
                lastEnd = max(lastEnd, end)
            }
        }
        guard count != publishedCount || lastEnd != publishedLastEnd else { return }
        publishedCount = count
        publishedLastEnd = lastEnd

        var segments: [SpeakerSegment] = []
        for (slot, speaker) in d.timeline.speakers {
            let label = speaker.name ?? "\(labelPrefix) \(speaker.index + 1)"
            labelBySlot[slot] = label
            harvestClip(slot: slot, from: speaker)
            for seg in speaker.finalizedSegments {
                segments.append(SpeakerSegment(
                    speaker: label,
                    start: TimeInterval(seg.startTime),
                    end: TimeInterval(seg.endTime)
                ))
            }
        }
        guard !segments.isEmpty else { return }
        segments.sort { $0.start < $1.start }
        onSegments?(segments)
    }

    /// Top up this speaker's voice clip from newly finalized segments still
    /// covered by the audio ring.
    private func harvestClip(slot: Int, from speaker: DiarizerSpeaker) {
        var clip = clips[slot] ?? ClipBuffer()
        defer { clips[slot] = clip }
        guard clip.rate <= 0 || Double(clip.samples.count) / clip.rate < VoiceProfileStore.maxClipSeconds
        else { return }

        for seg in speaker.finalizedSegments {
            let start = max(TimeInterval(seg.startTime), clip.consumedUntil)
            let end = TimeInterval(seg.endTime)
            guard end > start else { continue }
            clip.consumedUntil = end
            let (samples, rate) = ringExtract(from: start, to: end)
            guard !samples.isEmpty, rate > 0 else { continue }
            if clip.rate <= 0 { clip.rate = rate }
            guard rate == clip.rate else { continue }
            clip.samples.append(contentsOf: samples)
            if Double(clip.samples.count) / clip.rate >= VoiceProfileStore.maxClipSeconds {
                return
            }
        }
    }

    // MARK: - Audio ring (on queue)

    private func ringAppend(_ samples: [Float], rate: Double) {
        guard rate > 0, !samples.isEmpty else { return }
        ring.append((start: fedSeconds, rate: rate, samples: samples))
        fedSeconds += Double(samples.count) / rate
        let cutoff = fedSeconds - ringSeconds
        while let first = ring.first,
              first.start + Double(first.samples.count) / first.rate < cutoff {
            ring.removeFirst()
        }
    }

    /// Copy session audio for [from, to) out of the ring. Returns the chunk
    /// rate; spans predating the ring come back partial or empty.
    private func ringExtract(from: TimeInterval, to: TimeInterval) -> ([Float], Double) {
        var out: [Float] = []
        var rate: Double = 0
        for chunk in ring {
            let chunkEnd = chunk.start + Double(chunk.samples.count) / chunk.rate
            let s = max(from, chunk.start), e = min(to, chunkEnd)
            guard e > s else { continue }
            if rate <= 0 { rate = chunk.rate }
            guard chunk.rate == rate else { continue }
            let lo = Int((s - chunk.start) * chunk.rate)
            let hi = min(chunk.samples.count, Int((e - chunk.start) * chunk.rate))
            guard hi > lo else { continue }
            out.append(contentsOf: chunk.samples[lo..<hi])
        }
        return (out, rate)
    }

    /// "Them 2" → slot 1 when the slot was never published (early rename).
    private func slotFromLabel(_ label: String) -> Int? {
        guard label.hasPrefix(labelPrefix + " "),
              let n = Int(label.dropFirst(labelPrefix.count + 1)), n >= 1 else { return nil }
        return n - 1
    }
}
