import Foundation

/// Append-only debug log at /tmp/mc_debug.log. Callers are hot paths (per
/// utterance, per detection tick), so the file work happens on a serial
/// background queue with one long-lived handle — never open/seek/close on
/// the main thread per line.
private let mclogQueue = DispatchQueue(label: "mclog", qos: .utility)
// Touched only from mclogQueue (serial), hence the unsafe opt-outs.
nonisolated(unsafe) private let mclogFormatter = ISO8601DateFormatter()
private let mclogPath = "/tmp/mc_debug.log"
nonisolated(unsafe) private var mclogHandle: FileHandle?

func mclog(_ msg: String) {
    let now = Date()
    NSLog("%@", msg)
    mclogQueue.async {
        // Reopen when the file is gone: /tmp gets cleaned, and anything
        // (a dev session, the user) deleting the log used to leave a
        // long-running app writing to the unlinked inode forever — a whole
        // afternoon of a live-session bug report logged into the void
        // (2026-08-05).
        if mclogHandle == nil || !FileManager.default.fileExists(atPath: mclogPath) {
            mclogHandle?.closeFile()
            if !FileManager.default.fileExists(atPath: mclogPath) {
                FileManager.default.createFile(atPath: mclogPath, contents: nil)
            }
            mclogHandle = FileHandle(forWritingAtPath: mclogPath)
            mclogHandle?.seekToEndOfFile()
        }
        let line = "[\(mclogFormatter.string(from: now))] \(msg)\n"
        if let data = line.data(using: .utf8) {
            mclogHandle?.write(data)
        }
    }
}

