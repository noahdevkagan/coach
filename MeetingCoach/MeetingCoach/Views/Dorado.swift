import SwiftUI
import AppKit

// MARK: - Dorado design tokens (from the 2026-08-04 design handoff)
//
// Noah's direction after reviewing the full 2a layout: keep the COLORS,
// TYPE, and SIMPLICITY; keep the 0.12.0 structure and flow. So this file
// is the paint — tokens, fonts, and button styles — applied onto the
// pre-redesign views. The rail/tab re-architecture was reverted.

enum Dorado {
    // Color — every token is a light/dark pair so the app follows the
    // system appearance (Noah, 2026-08-05: "similar to computer on light
    // or dark or auto"). The handoff only specified the light values; the
    // dark side is the same hierarchy inverted onto near-black surfaces.
    static let dorado300 = Color(hex: 0xFFBC00)   // Go live, accents (both modes)
    static let dorado100 = Color(hex: 0xFFEE4E)   // hover, active highlight
    static let dorado500 = Color(hex: 0xF58A00)   // pressed
    static let doradoTint = dynamic(0xFFF3CC, 0x4A3F1E)  // soft highlight
    static let bolt = dynamic(0x0044C0, 0x5B9BFF)        // "You", links
    static let dollar = Color(hex: 0x00C838)      // success / loaded dot
    static let midnight = dynamic(0x021414, 0xF2F4F6)    // headings
    static let grey800 = dynamic(0x3C4552, 0xC9D1D9)     // body text
    static let grey600 = dynamic(0x647184, 0x9AA5B1)     // secondary text
    static let grey500 = Color(hex: 0x8B96A5)     // labels, icons (both modes)
    static let grey400 = dynamic(0xA6AFBB, 0x5C6670)     // timestamps, dates
    static let border = dynamic(0xDDE2E8, 0x3A4048)      // outline buttons, cards
    static let divider = dynamic(0xEDEFF2, 0x2A3036)     // hairlines
    static let surfaceSubtle = dynamic(0xF5F7F9, 0x262B31) // fields, selection
    static let warmSurface = dynamic(0xFCFBF8, 0x26241E) // warm cards
    static let warmBorder = dynamic(0xF1EDE4, 0x3B372C)
    /// Pane/window background — white in light, near-black in dark.
    static let surface = dynamic(0xFFFFFF, 0x1E2126)

    /// A color that resolves per the effective appearance at draw time.
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }

    // Type — bundled faces (Resources/Fonts, ATSApplicationFontsPath).
    // Font.custom silently falls back to the system face if a TTF ever
    // fails to register, so a font problem degrades instead of breaking.
    static func barlowBold(_ size: CGFloat) -> Font { .custom("Barlow-Bold", size: size) }
    static func barlowXBold(_ size: CGFloat) -> Font { .custom("Barlow-ExtraBold", size: size) }
    static func roboto(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Roboto", size: size).weight(weight)
    }
    static func mono(_ size: CGFloat) -> Font { .custom("Roboto Mono", size: size) }

    /// Parse the canonical date out of a session filename (either naming
    /// generation — TranscriptSearch owns the formats).
    static func sessionDate(_ url: URL) -> Date? {
        TranscriptSearch.sessionDate(for: url)
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

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
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
            .foregroundStyle(stop ? Dorado.surface : Dorado.midnight)
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
