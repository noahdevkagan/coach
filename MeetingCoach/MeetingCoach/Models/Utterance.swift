import Foundation

struct Utterance: Identifiable, Sendable {
    let id = UUID()
    let t: TimeInterval        // seconds from meeting start
    let speaker: String
    let text: String

    var isYou: Bool {
        let lower = speaker.trimmingCharacters(in: .whitespaces).lowercased()
        return ["you", "me", "self"].contains(lower)
    }

    var formattedTime: String {
        let mm = Int(t) / 60
        let ss = Int(t) % 60
        return String(format: "%02d:%02d", mm, ss)
    }
}
