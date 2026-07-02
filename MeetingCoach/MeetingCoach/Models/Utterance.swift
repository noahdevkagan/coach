import Foundation

struct Utterance: Identifiable, Sendable {
    let id = UUID()
    let t: TimeInterval        // seconds from meeting start
    let endT: TimeInterval     // when the utterance finished (== t if unknown)
    let speaker: String
    let text: String

    init(t: TimeInterval, speaker: String, text: String, endT: TimeInterval? = nil) {
        self.t = t
        self.speaker = speaker
        self.text = text
        self.endT = max(endT ?? t, t)
    }

    var duration: TimeInterval { endT - t }

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
