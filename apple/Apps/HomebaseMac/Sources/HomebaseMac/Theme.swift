import AppKit
import SwiftUI

/// Design tokens from the Homebase design. Dark values come straight from the design;
/// light values are chosen to match (M12: follow the system appearance).
enum Theme {
    static let background = dynamic(dark: 0x15171C, light: 0xF5F6F8)
    static let sidebar = dynamic(dark: 0x1A1D23, light: 0xECEEF2)
    static let card = dynamic(dark: 0x1C2027, light: 0xFFFFFF)
    static let selection = dynamic(dark: 0x262B35, light: 0xDDE1E8)
    static let border = dynamic(dark: 0x262A32, light: 0xD8DCE3)
    static let textPrimary = dynamic(dark: 0xE7E9ED, light: 0x1B1E24)
    static let textSecondary = dynamic(dark: 0xC9CDD6, light: 0x3A404B)
    static let textMuted = dynamic(dark: 0x9097A5, light: 0x626A78)
    static let accent = Color(hex: 0x6D8DFF)
    static let accentText = Color(hex: 0x0B1020)
    static let ok = Color(hex: 0x34D399)
    static let warn = dynamic(dark: 0xFBBF24, light: 0x9A6700)
    static let danger = dynamic(dark: 0xF87171, light: 0xC62828)
    static let warnBackground = dynamic(dark: 0x211D14, light: 0xFFF6DB)
    static let warnBorder = dynamic(dark: 0x4A3F1F, light: 0xEBD79A)
    static let warnChip = dynamic(dark: 0x2C2718, light: 0xFBEBB8)
    static let warnText = dynamic(dark: 0xE8D9A8, light: 0x5C4500)
    static let idle = Color(hex: 0x5A6170)

    static let cardRadius: CGFloat = 12

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

/// Card surface used by stat cards and panels.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.border))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// For custom-styled buttons: the whole label area is clickable (not just its text or glyphs),
/// the pointer becomes a hand, and the label dims while pressed.
struct PointerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .modifier(HandCursor())
    }
}

extension ButtonStyle where Self == PointerButtonStyle {
    static var pointer: PointerButtonStyle { PointerButtonStyle() }
}

struct HandCursor: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside && isEnabled && !pushed {
                    NSCursor.pointingHand.push(); pushed = true
                } else if (!inside || !isEnabled) && pushed {
                    NSCursor.pop(); pushed = false
                }
            }
            // A view that vanishes while hovered (screen switch, sheet) must not leave the hand stuck.
            .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
    }
}

extension View {
    /// Hand cursor while hovering. Use on clickable areas that are not a Button (e.g. a tappable row).
    func handCursor() -> some View { modifier(HandCursor()) }
}
