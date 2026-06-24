import Foundation

struct SignalFeedItem: Identifiable {
    let id = UUID()
    let t: TimeInterval
    let message: String
    let call: CoachingCall?

    init(t: TimeInterval, message: String, call: CoachingCall? = nil) {
        self.t = t
        self.message = message
        self.call = call
    }

    var isSignal: Bool { call != nil }

    var formattedTime: String {
        let mm = Int(t) / 60
        let ss = Int(t) % 60
        return String(format: "%02d:%02d", mm, ss)
    }
}
