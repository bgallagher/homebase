package com.bgallagher.rackoon.core

/**
 * The app's chrome colours (surfaces, text, status colours), derived from a terminal theme so one choice restyles everything.
 * Pure and deterministic; every text and status colour is clamped to a minimum contrast against the background so no theme can
 * make the app unreadable.
 */
data class AppPalette(
    val background: RGB,
    val sidebar: RGB,
    val card: RGB,
    val selection: RGB,
    val border: RGB,
    val textPrimary: RGB,
    val textSecondary: RGB,
    val textMuted: RGB,
    val accent: RGB,
    /** Text drawn on top of the accent colour (button labels). */
    val accentText: RGB,
    val ok: RGB,
    val warn: RGB,
    val danger: RGB,
    val idle: RGB,
    val warnBackground: RGB,
    val warnBorder: RGB,
    val warnChip: RGB,
    val warnText: RGB,
    /** Timestamps and captions: the faintest text that still reads (4.5:1). */
    val textDim: RGB,
    /** Status colours as families: `mark` for dots and bars, `label` for words, `fill`/`onFill` for tinted chips and tiles. */
    val okRole: PaletteRole,
    val warnRole: PaletteRole,
    val dangerRole: PaletteRole,
    /** The INFO level word and the Local scope. */
    val info: PaletteRole,
    val scopeLocal: PaletteRole,
    val scopeTailscale: PaletteRole,
    val scopePublic: PaletteRole,
    /** Six distinguishable colours for container names and letter tiles. Never red, yellow, green or blue, which mean something. */
    val series: List<PaletteRole>,
    val isDark: Boolean,
) {
    /**
     * One colour as a family, so a screen never hard-codes a shade: [mark] (3:1) is for dots, bars and icons, [label] (4.5:1)
     * for words, [fill] is a quiet tint over a card and [onFill] reads on it (4.5:1).
     */
    data class PaletteRole(val mark: RGB, val label: RGB, val fill: RGB, val onFill: RGB)

    /** Contrast floors (WCAG ratios). */
    object Contrast {
        const val PRIMARY = 7.0
        const val SECONDARY = 6.0
        const val MUTED = 4.5
        const val ACCENT = 3.0
        const val STATUS = 3.0
        const val ON_ACCENT = 4.5
        const val CHIP_TEXT = 4.5
        /** Words and tinted fills built from the palette roles. */
        const val LABEL = 4.5
        const val FILL_ALPHA = 0.18
        /** Series colours closer than this (sum of channel differences) count as the same. */
        const val SERIES_MIN_DISTANCE = 40
    }

    companion object {
        fun derive(theme: TerminalTheme): AppPalette {
            val bg = theme.backgroundRGB
            val fg = theme.foregroundRGB
            val ansi = theme.ansiRGB
            val dark = theme.isDark

            // Surfaces: stepped away from the background toward the foreground. On light themes cards go the other way (toward
            // white) so they still lift off the page.
            val sidebar = bg.mixed(fg, if (dark) 0.04 else 0.05)
            var card = if (dark) bg.mixed(fg, 0.06) else bg.mixed(RGB.WHITE, 0.65)
            // A pure-white page cannot get lighter: lift cards the other way so they still stand out.
            if (card.contrastRatio(bg) < 1.02) card = bg.mixed(fg, 0.035)
            val selection = bg.mixed(fg, if (dark) 0.12 else 0.10)
            val border = bg.mixed(fg, if (dark) 0.14 else 0.16)

            val textPrimary = fg.ensuringContrast(bg, Contrast.PRIMARY)
            val textSecondary = fg.mixed(bg, 0.15).ensuringContrast(bg, Contrast.SECONDARY)
            val textMuted = fg.mixed(bg, 0.40).ensuringContrast(bg, Contrast.MUTED)

            // Normal or bright variant, whichever reads better on this background (bright is often pale on light themes).
            fun pick(normal: Int, bright: Int): RGB {
                val a = ansi[normal]
                val b = ansi[bright]
                val best = if (a.contrastRatio(bg) >= b.contrastRatio(bg)) a else b
                return best.ensuringContrast(bg, Contrast.STATUS)
            }
            val accentSource = if (ansi[4].contrastRatio(bg) >= ansi[12].contrastRatio(bg)) ansi[4] else ansi[12]
            val accent = accentSource.ensuringContrast(bg, Contrast.ACCENT)
            // Black or white, whichever reads better. No clamp is needed: for ANY colour the better of the two has at least
            // sqrt(21) - 0.05 (about 4.53) contrast, which clears the 4.5 floor.
            val accentText = if (accent.contrastRatio(RGB.BLACK) >= accent.contrastRatio(RGB.WHITE)) RGB.BLACK else RGB.WHITE
            val warn = pick(3, 11)

            val chip = bg.mixed(warn, 0.18)
            val warnText = textPrimary.mixed(warn, 0.30).ensuringContrast(chip, Contrast.CHIP_TEXT)

            fun role(base: RGB): PaletteRole {
                // Each pair is nudged against both the page and the card, so a role reads on either.
                val mark = base.ensuringContrast(card, Contrast.STATUS).ensuringContrast(bg, Contrast.STATUS)
                val label = base.ensuringContrast(card, Contrast.LABEL).ensuringContrast(bg, Contrast.LABEL)
                val fill = card.mixed(mark, Contrast.FILL_ALPHA)
                return PaletteRole(mark, label, fill, label.ensuringContrast(fill, Contrast.LABEL))
            }
            // The unclamped base for a status or accent hue: normal or bright, whichever reads better on this background.
            fun base(normal: Int, bright: Int): RGB = if (ansi[normal].contrastRatio(bg) >= ansi[bright].contrastRatio(bg)) ansi[normal] else ansi[bright]
            val red = base(1, 9)
            val green = base(2, 10)
            val yellow = base(3, 11)
            val blue = base(4, 12)
            val magenta = base(5, 13)
            val cyan = base(6, 14)
            val orange = red.mixed(yellow, 0.5)
            val candidates = listOf(
                cyan, orange, magenta,
                blue.mixed(magenta, 0.5).mixed(fg, 0.2),   // lavender
                green.mixed(cyan, 0.5),                    // teal
                blue.mixed(fg, 0.45),                      // grey-blue
            )
            // Some themes reuse one hue for two slots (cyan equal to green, say): a colour too close to an earlier one is nudged
            // lighter or darker, keeping its hue, so two containers are never the same colour.
            fun far(a: RGB, b: RGB) = Math.abs(a.r - b.r) + Math.abs(a.g - b.g) + Math.abs(a.b - b.b) >= Contrast.SERIES_MIN_DISTANCE
            val series = mutableListOf<PaletteRole>()
            for (candidate in candidates) {
                var c = candidate
                var r = role(c)
                var tries = 0
                while (tries < 10 && series.any { !far(it.mark, r.mark) }) {
                    c = c.mixed(if (tries % 2 == 0) fg else bg, 0.22)
                    r = role(c)
                    tries++
                }
                series += r
            }

            return AppPalette(
                background = bg, sidebar = sidebar, card = card, selection = selection, border = border,
                textPrimary = textPrimary, textSecondary = textSecondary, textMuted = textMuted,
                accent = accent, accentText = accentText,
                ok = pick(2, 10), warn = warn, danger = pick(1, 9),
                idle = ansi[8].ensuringContrast(bg, Contrast.STATUS),
                warnBackground = bg.mixed(warn, 0.10), warnBorder = bg.mixed(warn, 0.30),
                warnChip = chip, warnText = warnText,
                textDim = fg.mixed(bg, 0.45).ensuringContrast(card, Contrast.MUTED).ensuringContrast(bg, Contrast.MUTED),
                okRole = role(green), warnRole = role(yellow), dangerRole = role(red),
                info = role(blue), scopeLocal = role(blue), scopeTailscale = role(magenta), scopePublic = role(orange),
                series = series, isDark = dark,
            )
        }
    }
}
