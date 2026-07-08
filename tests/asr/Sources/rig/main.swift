import AVFoundation
import Foundation

// Feeds a playlist of audio files (with silence gaps) through the REAL
// ParakeetPipeline in real time, emitting machine-readable UTT/PARTIAL lines.
//
// Usage: rig <playlist.json> <normal|cut>
//   normal — trailing 2.5s silence, then stop() (silence-gap commit path)
//   cut    — stop() immediately after the last sample (tail-flush path)

struct Item: Decodable {
    let file: String        // empty string = pure silence segment
    let gapAfter: Double    // seconds of zeros appended after the file
}

guard CommandLine.arguments.count > 1 else {
    print("Usage: rig <playlist.json> [normal|cut]")
    exit(2)
}
let playlistPath = CommandLine.arguments[1]
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "normal"
let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: playlistPath)))

let sessionStart = Date()
let pipeline = ParakeetPipeline(speaker: "Meeting", sessionStart: sessionStart)
var utteranceCount = 0
pipeline.onUtterance = { u in
    utteranceCount += 1
    let wall = String(format: "%.2f", Date().timeIntervalSince(sessionStart))
    print("UTT\t\(wall)\t\(String(format: "%.2f", u.t))\t\(String(format: "%.2f", u.endT))\t\(u.text)")
}
pipeline.onPartial = { p in
    let wall = String(format: "%.2f", Date().timeIntervalSince(sessionStart))
    print("PARTIAL\t\(wall)\t\(p)")
}

guard await ParakeetEngine.shared.ensureLoaded() else {
    print("FATAL\tengine failed to load")
    exit(1)
}
pipeline.start()

for item in items {
    if !item.file.isEmpty {
        let f = try AVAudioFile(forReading: URL(fileURLWithPath: item.file))
        let fmt = f.processingFormat
        let chunkFrames = AVAudioFrameCount(fmt.sampleRate / 10)   // 100 ms
        while f.framePosition < f.length {
            let n = min(chunkFrames, AVAudioFrameCount(f.length - f.framePosition))
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { break }
            try f.read(into: buf, frameCount: n)
            pipeline.append(buf)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        print("FED\t\(String(format: "%.2f", Date().timeIntervalSince(sessionStart)))\t\(item.file)")
    }
    if item.gapAfter > 0 {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
        let chunkFrames = AVAudioFrameCount(2205)
        for _ in 0..<Int(item.gapAfter * 10) {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkFrames) else { break }
            buf.frameLength = chunkFrames   // zero-initialized = silence
            pipeline.append(buf)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

if mode == "cut" {
    print("STOP\t\(String(format: "%.2f", Date().timeIntervalSince(sessionStart)))\tcut: stopping mid-stream")
    pipeline.stop()
} else {
    try await Task.sleep(nanoseconds: 2_500_000_000)
    pipeline.stop()
}
// Give the async tail flush time to land.
try await Task.sleep(nanoseconds: 4_000_000_000)
print("DONE\t\(utteranceCount)")
