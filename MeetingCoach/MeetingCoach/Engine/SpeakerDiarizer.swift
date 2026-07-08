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
/// Feed it the same mono mic buffers the recognizer gets; it periodically
/// publishes the full finalized segment list so utterances transcribed as
/// "Meeting" can be relabeled "Speaker 1/2/…". Everything runs locally —
/// the CoreML model is downloaded once to Application Support/FluidAudio.
final class SpeakerDiarizer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.coach.diarizer", qos: .utility)
    private var diarizer: LSEENDDiarizer?
    /// Audio arriving before the model finishes loading, so segment
    /// timestamps stay aligned with the session start. Capped below.
    private var preload: [(samples: [Float], rate: Double)] = []
    private var preloadSamples = 0
    private let preloadCap = 48_000 * 60 * 5  // ~5 min at 48kHz
    private var lastProcess = Date.distantPast
    private var stopped = false

    var onSegments: (@Sendable ([SpeakerSegment]) -> Void)?

    func start() {
        Task {
            do {
                // .dihard3: in-the-wild conversations — right for room audio
                // (in-person meetings, phone-on-speaker near the Mac).
                let d = try await LSEENDDiarizer(variant: .dihard3)
                self.queue.async {
                    guard !self.stopped else { return }
                    self.diarizer = d
                    for chunk in self.preload {
                        try? d.addAudio(chunk.samples, sourceSampleRate: chunk.rate)
                    }
                    self.preload = []
                    mclog("[Diarizer] Ready (LS-EEND dihard3)")
                }
            } catch {
                mclog("[Diarizer] Unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// Enqueue mono float samples from the mic tap. Safe from the tap thread.
    func enqueue(_ samples: [Float], sampleRate: Double) {
        queue.async {
            guard !self.stopped else { return }
            guard let d = self.diarizer else {
                if self.preloadSamples < self.preloadCap {
                    self.preload.append((samples, sampleRate))
                    self.preloadSamples += samples.count
                }
                return
            }
            do {
                try d.addAudio(samples, sourceSampleRate: sampleRate)
            } catch {
                mclog("[Diarizer] addAudio failed: \(error)")
                return
            }

            // Throttle inference + timeline reads to ~1/s.
            guard Date().timeIntervalSince(self.lastProcess) > 1.0 else { return }
            self.lastProcess = Date()
            do {
                _ = try d.process()
            } catch {
                mclog("[Diarizer] process failed: \(error)")
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
            self.diarizer = nil
            self.preload = []
        }
    }

    private func publish(from d: LSEENDDiarizer) {
        var segments: [SpeakerSegment] = []
        for (_, speaker) in d.timeline.speakers {
            let label = "Speaker \(speaker.index + 1)"
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
}
