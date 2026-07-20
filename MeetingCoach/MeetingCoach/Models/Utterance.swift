import Foundation

/// Call-relative seconds as "mm:ss" — the one timestamp format every model
/// and view uses. (Shared here; it was copy-pasted onto five types once.)
func mmss(_ t: TimeInterval) -> String {
    String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
}

struct Utterance: Identifiable, Sendable {
    let id = UUID()
    let t: TimeInterval        // seconds from meeting start
    let endT: TimeInterval     // when the utterance finished (== t if unknown)
    var speaker: String
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

    var formattedTime: String { mmss(t) }
}
