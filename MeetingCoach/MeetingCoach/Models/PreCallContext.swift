import Foundation

struct PreCallContext: Codable {
    var meetingGoal: String = ""
    var scheduledDurationMinutes: Int = 30
    var participants: [Participant] = []
    var activePlaybook: String = ""
    var lastMeetingNotes: String = ""
    var myKnownTendencies: [String] = []
    /// Set explicitly only in rare paths (e.g. tests); normally nil and the
    /// type is inferred from goal, roles, and participant count.
    var meetingType: MeetingType?

    var effectiveMeetingType: MeetingType { meetingType ?? inferredMeetingType }

    /// Infers the meeting type instead of asking the user for it.
    /// Sales cues win over headcount, since a sales call can have any number
    /// of people on it. Goal text gets the full cue list; participant roles
    /// only the external-party cues — a teammate whose role is "sales" or
    /// "cro" doesn't make the meeting a sales call.
    var inferredMeetingType: MeetingType {
        let goalCues = [
            "deal", "sale", "sell", "close", "closing", "prospect", "customer",
            "client", "pricing", "demo", "pitch", "discovery",
            "renewal", "upsell", "negotiat", "contract", "buyer",
        ]
        let externalRoleCues = ["prospect", "customer", "client", "buyer", "lead"]

        let goal = meetingGoal.lowercased()
        let roles = participants.map { $0.role.lowercased() }
        if goalCues.contains(where: goal.contains)
            || roles.contains(where: { role in externalRoleCues.contains(where: role.contains) }) {
            return .salesCall
        }

        let headcount = participants.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }.count
        switch headcount {
        case 1: return .oneOnOne
        case 3...: return .teamMeeting
        default: return .general
        }
    }

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
