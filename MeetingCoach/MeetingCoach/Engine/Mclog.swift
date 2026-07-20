import Foundation

/// Append-only debug log at /tmp/mc_debug.log. Callers are hot paths (per
/// utterance, per detection tick), so the file work happens on a serial
/// background queue with one long-lived handle — never open/seek/close on
/// the main thread per line.
private let mclogQueue = DispatchQueue(label: "mclog", qos: .utility)
// Touched only from mclogQueue (serial), hence the unsafe opt-out.
nonisolated(unsafe) private let mclogFormatter = ISO8601DateFormatter()
nonisolated(unsafe) private let mclogHandle: FileHandle? = {
    let path = "/tmp/mc_debug.log"
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    let fh = FileHandle(forWritingAtPath: path)
    fh?.seekToEndOfFile()
    return fh
}()

func mclog(_ msg: String) {
    let now = Date()
    NSLog("%@", msg)
    mclogQueue.async {
        let line = "[\(mclogFormatter.string(from: now))] \(msg)\n"
        if let data = line.data(using: .utf8) {
            mclogHandle?.write(data)
        }
    }
}

