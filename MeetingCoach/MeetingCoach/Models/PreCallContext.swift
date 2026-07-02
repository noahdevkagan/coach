import Foundation

struct PreCallContext: Codable {
    var meetingGoal: String = ""
    var scheduledDurationMinutes: Int = 30
    var participants: [Participant] = []
    var activePlaybook: String = ""
    var lastMeetingNotes: String = ""
    var myKnownTendencies: [String] = []
    /// Optional so contexts persisted before this field decode cleanly.
    var meetingType: MeetingType?

    var effectiveMeetingType: MeetingType { meetingType ?? .general }

    struct Participant: Codable, Identifiable {
        var id = UUID()
        var name: String = ""
        var role: String = ""
    }
}

/// The kind of meeting changes what good facilitation looks like: long turns
/// are the FORMAT of an advisory 1:1 but a red flag on a sales call. Signals
/// scale their thresholds by these multipliers.
enum MeetingType: String, Codable, CaseIterable, Identifiable {
    case general
    case oneOnOne      // 1:1 / advisory — long updates are expected
    case salesCall     // deal call — discovery and listening matter most
    case teamMeeting   // group — "Them" aggregates many voices

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general: return "General"
        case .oneOnOne: return "1:1 / Advisory"
        case .salesCall: return "Sales / Deal"
        case .teamMeeting: return "Team / Group"
        }
    }

    /// >1 relaxes talk-time (longer turns tolerated).
    var talkTimeMultiplier: Double {
        switch self {
        case .general: return 1.0
        case .oneOnOne: return 2.0
        case .salesCall: return 0.75
        case .teamMeeting: return 1.5
        }
    }

    /// >1 relaxes engagement signals (goingQuiet, yesMan).
    var engagementMultiplier: Double {
        switch self {
        case .general: return 1.0
        case .oneOnOne: return 2.0
        case .salesCall: return 1.0
        case .teamMeeting: return 1.5
        }
    }

    /// >1 relaxes the ask-questions pressure (missingDiscovery).
    var discoveryMultiplier: Double {
        switch self {
        case .general: return 1.0
        case .oneOnOne: return 1.5
        case .salesCall: return 0.75
        case .teamMeeting: return 1.5
        }
    }
}
