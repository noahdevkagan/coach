import SwiftUI
import AppKit

// MARK: - Dorado design tokens (from the 2026-08-04 design handoff)
//
// Noah's direction after reviewing the full 2a layout: keep the COLORS,
// TYPE, and SIMPLICITY; keep the 0.12.0 structure and flow. So this file
// is the paint — tokens, fonts, and button styles — applied onto the
// pre-redesign views. The rail/tab re-architecture was reverted.

enum Dorado {
    // Color
    static let dorado300 = Color(hex: 0xFFBC00)   // Go live, accents
    static let dorado100 = Color(hex: 0xFFEE4E)   // hover, active highlight
    static let dorado500 = Color(hex: 0xF58A00)   // pressed
    static let doradoTint = Color(hex: 0xFFF3CC)  // soft highlight
    static let bolt = Color(hex: 0x0044C0)        // "You", links
    static let dollar = Color(hex: 0x00C838)      // success / loaded dot
    static let midnight = Color(hex: 0x021414)    // headings
    static let grey800 = Color(hex: 0x3C4552)     // body text
    static let grey600 = Color(hex: 0x647184)     // secondary text
    static let grey500 = Color(hex: 0x8B96A5)     // labels, icons, meta
    static let grey400 = Color(hex: 0xA6AFBB)     // timestamps, dates
    static let border = Color(hex: 0xDDE2E8)      // outline buttons, cards
    static let divider = Color(hex: 0xEDEFF2)     // hairlines
    static let surfaceSubtle = Color(hex: 0xF5F7F9) // fields, selection
    static let warmSurface = Color(hex: 0xFCFBF8) // warm cards
    static let warmBorder = Color(hex: 0xF1EDE4)

    // Type — bundled faces (Resources/Fonts, ATSApplicationFontsPath).
    // Font.custom silently falls back to the system face if a TTF ever
    // fails to register, so a font problem degrades instead of breaking.
    static func barlowBold(_ size: CGFloat) -> Font { .custom("Barlow-Bold", size: size) }
    static func barlowXBold(_ size: CGFloat) -> Font { .custom("Barlow-ExtraBold", size: size) }
    static func roboto(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Roboto", size: size).weight(weight)
    }
    static func mono(_ size: CGFloat) -> Font { .custom("Roboto Mono", size: size) }

    /// 11px all-caps label with 0.1em tracking — the only sub-12px style.
    static func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(roboto(11, .bold))
            .kerning(1.1)
            .foregroundStyle(grey500)
    }

    /// Parse the canonical date out of "session_yyyy-MM-dd_HH-mm.md".
    static func sessionDate(_ url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("session_") else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return f.date(from: String(name.dropFirst("session_".count)))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The app's single primary action pill (Go live). Hover #FFEE4E, press
/// #F58A00, no scale transform.
struct DoradoPillButtonStyle: ButtonStyle {
    var stop = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Dorado.barlowBold(16))
            .foregroundStyle(stop ? Color.white : Dorado.midnight)
            .frame(maxWidth: .infinity)
            .padding(13)
            .background(background(pressed: configuration.isPressed))
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15), value: hovering)
    }

    private func background(pressed: Bool) -> Color {
        if stop { return pressed ? Dorado.grey800 : Dorado.midnight }
        if pressed { return Dorado.dorado500 }
        return hovering ? Dorado.dorado100 : Dorado.dorado300
    }
}

/// Outline pill (Copy/Export/Home). 1px #DDE2E8, hover border #021414.
struct DoradoOutlineButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Dorado.roboto(13, .medium))
            .foregroundStyle(Dorado.grey800)
            .padding(.vertical, 8).padding(.horizontal, 15)
            .background(Capsule().strokeBorder(hovering ? Dorado.midnight : Dorado.border, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15), value: hovering)
    }
}
