import AppKit
import Foundation

/// Builds the shareable post-meeting recap: the review text framed with the
/// session facts, ready to paste into Slack or email. This is the one
/// artifact of a session that's meant to leave the machine — sharing is
/// always an explicit user action (copy button / share sheet).
enum RecapExporter {

    /// DateFormatter construction is expensive and this runs in view bodies.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func markdown(summary: String,
                         context: PreCallContext,
                         durationMinutes: Int,
                         talkShare: Double?,
                         date: Date = Date()) -> String {
        let formatter = Self.dateFormatter

        var lines: [String] = []
        lines.append("# Meeting recap — \(formatter.string(from: date))")
        var facts = "\(durationMinutes) min"
        if !context.meetingGoal.isEmpty {
            facts += " · goal: \(context.meetingGoal)"
        }
        if let share = talkShare {
            facts += " · talk ratio \(Int(share * 100))% me"
        }
        lines.append(facts)
        lines.append("")
        lines.append(summary.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        lines.append("— coached locally by Meeting Coach")
        return lines.joined(separator: "\n")
    }

    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
