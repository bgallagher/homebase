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
    /// Timestamps and captions: the faintest text that still reads (4.5:1).
    public var textDim: RGB
    /// Status colours as families: `mark` for dots and bars, `label` for words, `fill`/`onFill` for tinted chips and tiles.
    public var okRole: PaletteRole
    public var warnRole: PaletteRole
    public var dangerRole: PaletteRole
    /// The INFO level word and the Local scope.
    public var info: PaletteRole
    public var scopeLocal: PaletteRole
    public var scopeTailscale: PaletteRole
    public var scopePublic: PaletteRole
    /// Six distinguishable colours for container names and letter tiles. Never red, yellow, green or blue, which mean something.
    public var series: [PaletteRole]
    public var isDark: Bool

    /// One colour as a family, so a screen never hard-codes a shade: `mark` (3:1) is for dots, bars and icons, `label` (4.5:1)
    /// for words, `fill` is a quiet tint over a card and `onFill` reads on it (4.5:1).
    public struct PaletteRole: Sendable, Equatable {
        public var mark: RGB
        public var label: RGB
        public var fill: RGB
        public var onFill: RGB
    }

    /// Contrast floors (WCAG ratios).
    public enum Contrast {
        public static let primary = 7.0
        public static let secondary = 6.0
        public static let muted = 4.5
        public static let accent = 3.0
        public static let status = 3.0
        public static let onAccent = 4.5
        public static let chipText = 4.5
        /// Words and tinted fills built from the palette roles.
        public static let label = 4.5
        public static let fillAlpha = 0.18
        /// Series colours closer than this (sum of channel differences) count as the same.
        public static let seriesMinDistance: Int = 40
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

        func role(_ base: RGB) -> PaletteRole {
            // Each pair is nudged against both the page and the card, so a role reads on either.
            let mark = base.ensuringContrast(against: card, minimum: Contrast.status).ensuringContrast(against: bg, minimum: Contrast.status)
            let label = base.ensuringContrast(against: card, minimum: Contrast.label).ensuringContrast(against: bg, minimum: Contrast.label)
            let fill = card.mixed(with: mark, amount: Contrast.fillAlpha)
            return PaletteRole(mark: mark, label: label, fill: fill, onFill: label.ensuringContrast(against: fill, minimum: Contrast.label))
        }
        // The unclamped base for a status or accent hue: normal or bright, whichever reads better on this background.
        func base(_ normal: Int, _ bright: Int) -> RGB {
            ansi[normal].contrastRatio(with: bg) >= ansi[bright].contrastRatio(with: bg) ? ansi[normal] : ansi[bright]
        }
        let red = base(1, 9), green = base(2, 10), yellow = base(3, 11)
        let blue = base(4, 12), magenta = base(5, 13), cyan = base(6, 14)
        let orange = red.mixed(with: yellow, amount: 0.5)
        let candidates = [
            cyan, orange, magenta,
            blue.mixed(with: magenta, amount: 0.5).mixed(with: fg, amount: 0.2),   // lavender
            green.mixed(with: cyan, amount: 0.5),                                  // teal
            blue.mixed(with: fg, amount: 0.45),                                    // grey-blue
        ]
        // Some themes reuse one hue for two slots (cyan equal to green, say): a colour too close to an earlier one is nudged
        // lighter or darker, keeping its hue, so two containers are never the same colour.
        func far(_ a: RGB, _ b: RGB) -> Bool {
            let dr = abs(Int(a.r) - Int(b.r)), dg = abs(Int(a.g) - Int(b.g)), db = abs(Int(a.b) - Int(b.b))
            return dr + dg + db >= Contrast.seriesMinDistance
        }
        var series: [PaletteRole] = []
        for candidate in candidates {
            var c = candidate
            var r = role(c)
            var tries = 0
            while tries < 10 && series.contains(where: { !far($0.mark, r.mark) }) {
                c = c.mixed(with: tries % 2 == 0 ? fg : bg, amount: 0.22)
                r = role(c)
                tries += 1
            }
            series.append(r)
        }

        return AppPalette(
            background: bg, sidebar: sidebar, card: card, selection: selection, border: border,
            textPrimary: textPrimary, textSecondary: textSecondary, textMuted: textMuted,
            accent: accent, accentText: accentText,
            ok: pick(2, 10), warn: warn, danger: pick(1, 9),
            idle: ansi[8].ensuringContrast(against: bg, minimum: Contrast.status),
            warnBackground: bg.mixed(with: warn, amount: 0.10),
            warnBorder: bg.mixed(with: warn, amount: 0.30),
            warnChip: chip, warnText: warnText,
            textDim: fg.mixed(with: bg, amount: 0.45).ensuringContrast(against: card, minimum: Contrast.muted)
                .ensuringContrast(against: bg, minimum: Contrast.muted),
            okRole: role(green), warnRole: role(yellow), dangerRole: role(red),
            info: role(blue), scopeLocal: role(blue), scopeTailscale: role(magenta), scopePublic: role(orange),
            series: series, isDark: dark)
    }
}
