import Foundation

/// The app's chrome colours (sidebar, cards, text, status colours), derived from a terminal theme so one
/// choice restyles everything. Pure and deterministic; every text and status colour is clamped to a
/// minimum contrast against the background so no theme can make the app unreadable.
public struct AppPalette: Sendable, Equatable {
    public var background: RGB
    public var sidebar: RGB
    public var card: RGB
    public var selection: RGB
    public var border: RGB
    public var textPrimary: RGB
    public var textSecondary: RGB
    public var textMuted: RGB
    public var accent: RGB
    /// Text drawn on top of the accent colour (button labels).
    public var accentText: RGB
    public var ok: RGB
    public var warn: RGB
    public var danger: RGB
    public var idle: RGB
    public var warnBackground: RGB
    public var warnBorder: RGB
    public var warnChip: RGB
    public var warnText: RGB
    public var isDark: Bool

    /// Contrast floors (WCAG ratios).
    public enum Contrast {
        public static let primary = 7.0
        public static let secondary = 6.0
        public static let muted = 4.5
        public static let accent = 3.0
        public static let status = 3.0
        public static let onAccent = 4.5
        public static let chipText = 4.5
    }

    public static func derive(from theme: TerminalTheme) -> AppPalette {
        let bg = theme.backgroundRGB
        let fg = theme.foregroundRGB
        let ansi = theme.ansiRGB
        let dark = theme.isDark

        // Surfaces: stepped away from the background toward the foreground. On light themes cards go the
        // other way (toward white) so they still lift off the page, as in the design.
        let sidebar = bg.mixed(with: fg, amount: dark ? 0.04 : 0.05)
        var card = dark ? bg.mixed(with: fg, amount: 0.06) : bg.mixed(with: .white, amount: 0.65)
        // A pure-white page cannot get lighter: lift cards the other way so they still stand out.
        if card.contrastRatio(with: bg) < 1.02 { card = bg.mixed(with: fg, amount: 0.035) }
        let selection = bg.mixed(with: fg, amount: dark ? 0.12 : 0.10)
        let border = bg.mixed(with: fg, amount: dark ? 0.14 : 0.16)

        let textPrimary = fg.ensuringContrast(against: bg, minimum: Contrast.primary)
        let textSecondary = fg.mixed(with: bg, amount: 0.15).ensuringContrast(against: bg, minimum: Contrast.secondary)
        let textMuted = fg.mixed(with: bg, amount: 0.40).ensuringContrast(against: bg, minimum: Contrast.muted)

        // Normal or bright variant, whichever reads better on this background (bright is often pale on light themes).
        func pick(_ normal: Int, _ bright: Int) -> RGB {
            let a = ansi[normal], b = ansi[bright]
            let best = a.contrastRatio(with: bg) >= b.contrastRatio(with: bg) ? a : b
            return best.ensuringContrast(against: bg, minimum: Contrast.status)
        }
        let accentSource = ansi[4].contrastRatio(with: bg) >= ansi[12].contrastRatio(with: bg) ? ansi[4] : ansi[12]
        let accent = accentSource.ensuringContrast(against: bg, minimum: Contrast.accent)
        // Black or white, whichever reads better. No clamp is needed: for ANY colour the better of the two has at
        // least sqrt(21) - 0.05 (about 4.53) contrast, which clears the 4.5 floor. AppPaletteTests sweeps this.
        let accentText: RGB = accent.contrastRatio(with: .black) >= accent.contrastRatio(with: .white) ? .black : .white
        let warn = pick(3, 11)

        let chip = bg.mixed(with: warn, amount: 0.18)
        let warnText = textPrimary.mixed(with: warn, amount: 0.30).ensuringContrast(against: chip, minimum: Contrast.chipText)

        return AppPalette(
            background: bg, sidebar: sidebar, card: card, selection: selection, border: border,
            textPrimary: textPrimary, textSecondary: textSecondary, textMuted: textMuted,
            accent: accent, accentText: accentText,
            ok: pick(2, 10), warn: warn, danger: pick(1, 9),
            idle: ansi[8].ensuringContrast(against: bg, minimum: Contrast.status),
            warnBackground: bg.mixed(with: warn, amount: 0.10),
            warnBorder: bg.mixed(with: warn, amount: 0.30),
            warnChip: chip, warnText: warnText, isDark: dark)
    }
}
