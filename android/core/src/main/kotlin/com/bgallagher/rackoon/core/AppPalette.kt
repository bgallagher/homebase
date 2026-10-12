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
    val isDark: Boolean,
) {
    /** Contrast floors (WCAG ratios). */
    object Contrast {
        const val PRIMARY = 7.0
        const val SECONDARY = 6.0
        const val MUTED = 4.5
        const val ACCENT = 3.0
        const val STATUS = 3.0
        const val ON_ACCENT = 4.5
        const val CHIP_TEXT = 4.5
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

            return AppPalette(
                background = bg, sidebar = sidebar, card = card, selection = selection, border = border,
                textPrimary = textPrimary, textSecondary = textSecondary, textMuted = textMuted,
                accent = accent, accentText = accentText,
                ok = pick(2, 10), warn = warn, danger = pick(1, 9),
                idle = ansi[8].ensuringContrast(bg, Contrast.STATUS),
                warnBackground = bg.mixed(warn, 0.10), warnBorder = bg.mixed(warn, 0.30),
                warnChip = chip, warnText = warnText, isDark = dark,
            )
        }
    }
}
