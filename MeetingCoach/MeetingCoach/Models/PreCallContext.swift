import Foundation

struct PreCallContext: Codable {
    var meetingGoal: String = ""
    var scheduledDurationMinutes: Int = 30
    var participants: [Participant] = []
    var activePlaybook: String = ""
    var lastMeetingNotes: String = ""
    var myKnownTendencies: [String] = []

    struct Participant: Codable, Identifiable {
        var id = UUID()
        var name: String = ""
        var role: String = ""
    }
}
