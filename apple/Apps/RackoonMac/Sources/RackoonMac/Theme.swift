import AppKit
import RackoonCore
import SwiftUI

/// The app's colours, derived from the selected theme (see AppPalette). Properties read the shared
/// AppearanceStore, so any view that reads them inside `body` updates when the theme changes.
@MainActor
enum Theme {
    private static var p: AppPalette { AppearanceStore.shared.palette }

    static var background: Color { Color(rgb: p.background) }
    static var sidebar: Color { Color(rgb: p.sidebar) }
    static var card: Color { Color(rgb: p.card) }
    static var selection: Color { Color(rgb: p.selection) }
    static var border: Color { Color(rgb: p.border) }
    static var textPrimary: Color { Color(rgb: p.textPrimary) }
    static var textSecondary: Color { Color(rgb: p.textSecondary) }
    static var textMuted: Color { Color(rgb: p.textMuted) }
    static var accent: Color { Color(rgb: p.accent) }
    static var accentText: Color { Color(rgb: p.accentText) }
    static var ok: Color { Color(rgb: p.ok) }
    static var warn: Color { Color(rgb: p.warn) }
    static var danger: Color { Color(rgb: p.danger) }
    static var warnBackground: Color { Color(rgb: p.warnBackground) }
    static var warnBorder: Color { Color(rgb: p.warnBorder) }
    static var warnChip: Color { Color(rgb: p.warnChip) }
    static var warnText: Color { Color(rgb: p.warnText) }
    static var idle: Color { Color(rgb: p.idle) }

    static let cardRadius: CGFloat = 12

    /// For AppKit views that need an NSColor.
    static var sidebarNS: NSColor { p.sidebar.nsColor }
}

extension RGB {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

extension Color {
    init(rgb: RGB) { self.init(nsColor: rgb.nsColor) }
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

/// Hand cursor over clickable views.
/// macOS 15+ uses SwiftUI's own pointer API, which the system manages (no push/pop to unbalance).
/// macOS 14 falls back to setting the cursor from continuous hover events, with no cursor stack either.
/// An earlier attempt using AppKit cursor rects on a hit-test-transparent background view never
/// took effect, so do not go back to that.
struct HandCursor: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(isEnabled ? .link : nil)
        } else {
            content.onContinuousHover { phase in
                switch phase {
                case .active: if isEnabled { NSCursor.pointingHand.set() }
                case .ended: NSCursor.arrow.set()
                }
            }
        }
    }
}

extension View {
    /// Hand cursor while hovering. Use on clickable areas that are not a Button (e.g. a tappable row).
    func handCursor() -> some View { modifier(HandCursor()) }
}
