import AVFoundation
import Foundation

// Shims for app symbols ParakeetTranscriber.swift references, so the real
// file compiles unmodified inside the rig.

protocol TranscriptionPipeline: AnyObject {
    var onUtterance: ((Utterance) -> Void)? { get set }
    var onPartial: ((String) -> Void)? { get set }
    func start()
    func stop()
    func append(_ buffer: AVAudioPCMBuffer)
}

func mclog(_ msg: String) {
    let ts = String(format: "%.2f", Date().timeIntervalSince(rigStart))
    FileHandle.standardError.write("[\(ts)] \(msg)\n".data(using: .utf8)!)
}

let rigStart = Date()
