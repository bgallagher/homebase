package com.bgallagher.rackoon.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class TerminalThemeTests {
    @Test fun hexParsing() {
        assertEquals(RGB(0x6D, 0x8D, 0xFF), RGB.fromHex("#6D8DFF"))
        assertEquals(RGB(0x6D, 0x8D, 0xFF), RGB.fromHex("6d8dff"), "no hash, lowercase")
        assertEquals("#000000", RGB.fromHex(" #000000 ")?.hex)
        for (bad in listOf("", "#FFF", "#12345", "#1234567", "#GGGGGG", "red", "#12 456")) assertNull(RGB.fromHex(bad), bad)
        assertEquals("#6D8DFF", RGB.fromHex("#6D8DFF")?.hex, "round trip")
    }

    @Test fun luminance() {
        assertEquals(0.0, RGB.fromHex("#000000")!!.luminance, 0.0001)
        assertEquals(1.0, RGB.fromHex("#FFFFFF")!!.luminance, 0.0001)
        assertTrue(RGB.fromHex("#15171C")!!.luminance < 0.05)
        assertTrue(RGB.fromHex("#F5F6F8")!!.luminance > 0.9)
    }

    @Test fun bundledCatalogIsValid() {
        val themes = ThemeCatalog.bundled()
        assertEquals(45, themes.size)
        assertTrue(themes.any { it.id == ThemeCatalog.DEFAULT_ID })
        assertTrue(themes.any { it.isDark } && themes.any { !it.isDark }, "ships both dark and light")
    }

    private fun theme(id: String = "t", appearance: String = "dark", background: String = "#101010", ansi: List<String>? = null) =
        TerminalTheme(id, id, "F", appearance, background, "#EEEEEE", ansi = ansi ?: List(16) { "#808080" })

    @Test fun validationRejectsBrokenThemes() {
        val good = theme(ThemeCatalog.DEFAULT_ID)
        val goodLight = theme(ThemeCatalog.LIGHT_DEFAULT_ID, "light", "#F5F5F5")
        val base = listOf(good, goodLight)
        ThemeCatalog.validate(base)
        assertFailsWith<ThemeCatalogError>("duplicate id") { ThemeCatalog.validate(base + good) }
        assertFailsWith<ThemeCatalogError>("15 colours") { ThemeCatalog.validate(base + theme(ansi = List(15) { "#808080" })) }
        assertFailsWith<ThemeCatalogError>("bad hex") { ThemeCatalog.validate(base + theme(background = "#GGGGGG")) }
        assertFailsWith<ThemeCatalogError>("bad appearance") { ThemeCatalog.validate(base + theme("x", "sepia")) }
        assertFailsWith<ThemeCatalogError>("labelled light but dark") { ThemeCatalog.validate(base + theme("x", "light", "#101010")) }
        assertFailsWith<ThemeCatalogError>("default theme must exist") { ThemeCatalog.validate(listOf(theme("no-default"))) }
        assertFailsWith<ThemeCatalogError>("the light default must exist too") { ThemeCatalog.validate(listOf(good)) }
        val badANSI = List(16) { if (it == 7) "nope" else "#808080" }
        assertFailsWith<ThemeCatalogError>("bad ANSI entry") { ThemeCatalog.validate(base + theme("y", ansi = badANSI)) }
    }

    @Test fun malformedJSONFailsLoudly() {
        assertFailsWith<ThemeCatalogError> { ThemeCatalog.load("""[{"id": 1}]""") }
        assertFailsWith<ThemeCatalogError> { ThemeCatalog.load("not json") }
    }

    @Test fun missingCursorAndSelectionFallBack() {
        val t = theme()
        assertEquals(t.foregroundRGB, t.cursorRGB)
        assertEquals(t.foregroundRGB, t.selectionRGB)
    }
}

class AppPaletteTests {
    private val themes by lazy { ThemeCatalog.bundled() }

    @Test fun mixAndContrast() {
        assertEquals(RGB(128, 128, 128), RGB.BLACK.mixed(RGB.WHITE, 0.5))
        assertEquals(RGB.BLACK, RGB.BLACK.mixed(RGB.WHITE, 0.0))
        assertEquals(RGB.WHITE, RGB.BLACK.mixed(RGB.WHITE, 1.0))
        assertEquals(RGB.WHITE, RGB.BLACK.mixed(RGB.WHITE, 7.0), "amount is clamped")
        assertEquals(21.0, RGB.BLACK.contrastRatio(RGB.WHITE), 0.001)
        assertEquals(1.0, RGB.WHITE.contrastRatio(RGB.WHITE), 0.001)
        assertEquals(4.48, RGB.fromHex("#777777")!!.contrastRatio(RGB.WHITE), 0.02, "known WCAG reference value")
    }

    @Test fun ensuringContrastNudgesTowardTheReadableEnd() {
        val darkBG = RGB.fromHex("#101010")!!
        val dim = RGB.fromHex("#303030")!!
        val fixed = dim.ensuringContrast(darkBG, 4.5)
        assertTrue(fixed.contrastRatio(darkBG) >= 4.5)
        assertTrue(fixed.luminance > dim.luminance, "lightened on a dark background")

        val lightBG = RGB.fromHex("#F0F0F0")!!
        val pale = RGB.fromHex("#C0C0C0")!!
        val darker = pale.ensuringContrast(lightBG, 4.5)
        assertTrue(darker.contrastRatio(lightBG) >= 4.5)
        assertTrue(darker.luminance < pale.luminance, "darkened on a light background")

        val fine = RGB.fromHex("#EEEEEE")!!
        assertEquals(fine, fine.ensuringContrast(darkBG, 4.5), "already fine: unchanged")
    }

    @Test fun anythingIsReachableEvenOnAMidGreyBackground() {
        val mid = RGB.fromHex("#777777")!!
        assertTrue(mid.bestPossibleContrast >= 4.5, "4.5 is always achievable, which is why it is the muted floor")
        val c = RGB.fromHex("#808080")!!.ensuringContrast(mid, 6.0)
        assertTrue(c.contrastRatio(mid) >= minOf(6.0, mid.bestPossibleContrast) - 0.01, "an unreachable floor falls back to the best possible")
    }

    @Test fun blackOrWhiteAlwaysClearsTheOnAccentFloor() {
        var worst = Double.POSITIVE_INFINITY
        for (r in 0..255 step 15) for (g in 0..255 step 15) for (b in 0..255 step 15) worst = minOf(worst, RGB(r, g, b).bestPossibleContrast)
        assertTrue(worst >= AppPalette.Contrast.ON_ACCENT)
    }

    @Test fun automaticResolution() {
        assertEquals("rackoon-dark", ThemeCatalog.resolve("automatic", true, themes)?.id)
        assertEquals("rackoon-light", ThemeCatalog.resolve("automatic", false, themes)?.id)
        assertEquals("dracula", ThemeCatalog.resolve("dracula", false, themes)?.id, "an explicit choice ignores the system appearance")
        assertEquals("rackoon-light", ThemeCatalog.resolve("no-such-theme", false, themes)?.id, "an unknown id falls back to Automatic")
        assertNull(ThemeCatalog.resolve("automatic", true, emptyList()))
    }

    @Test fun everyBundledThemeMeetsTheContrastFloors() {
        assertTrue(themes.size >= 40)
        for (t in themes) {
            val p = AppPalette.derive(t)
            val bg = p.background
            fun atLeast(name: String, c: RGB, against: RGB, floor: Double) {
                val need = minOf(floor, against.bestPossibleContrast)
                assertTrue(c.contrastRatio(against) >= need - 0.01, "${t.id}: $name ${c.hex} on ${against.hex} is ${"%.2f".format(c.contrastRatio(against))}, needs $need")
            }
            atLeast("textPrimary", p.textPrimary, bg, AppPalette.Contrast.PRIMARY)
            atLeast("textSecondary", p.textSecondary, bg, AppPalette.Contrast.SECONDARY)
            atLeast("textMuted", p.textMuted, bg, AppPalette.Contrast.MUTED)
            atLeast("textMuted on card", p.textMuted, p.card, AppPalette.Contrast.MUTED - 0.7)
            atLeast("accent", p.accent, bg, AppPalette.Contrast.ACCENT)
            atLeast("ok", p.ok, bg, AppPalette.Contrast.STATUS)
            atLeast("warn", p.warn, bg, AppPalette.Contrast.STATUS)
            atLeast("danger", p.danger, bg, AppPalette.Contrast.STATUS)
            atLeast("idle", p.idle, bg, AppPalette.Contrast.STATUS)
            atLeast("accentText on accent", p.accentText, p.accent, AppPalette.Contrast.ON_ACCENT)
            atLeast("warnText on warnChip", p.warnText, p.warnChip, AppPalette.Contrast.CHIP_TEXT)
            assertEquals(t.isDark, p.isDark)
        }
    }

    @Test fun everyRoleFamilyReadsOnEveryTheme() {
        for (t in themes) {
            val p = AppPalette.derive(t)
            fun atLeast(name: String, c: RGB, against: RGB, floor: Double) {
                val need = minOf(floor, against.bestPossibleContrast)
                assertTrue(c.contrastRatio(against) >= need - 0.01, "${t.id}: $name ${c.hex} on ${against.hex} is ${"%.2f".format(c.contrastRatio(against))}, needs $need")
            }
            atLeast("textDim", p.textDim, p.background, AppPalette.Contrast.MUTED)
            val roles = listOf(
                "ok" to p.okRole, "warn" to p.warnRole, "danger" to p.dangerRole, "info" to p.info, "scopeLocal" to p.scopeLocal,
                "scopeTailscale" to p.scopeTailscale, "scopePublic" to p.scopePublic,
            ) + p.series.mapIndexed { i, r -> "series$i" to r }
            for ((name, r) in roles) {
                atLeast("$name mark", r.mark, p.background, AppPalette.Contrast.STATUS)
                atLeast("$name mark on card", r.mark, p.card, AppPalette.Contrast.STATUS)
                atLeast("$name label", r.label, p.background, AppPalette.Contrast.LABEL)
                atLeast("$name label on card", r.label, p.card, AppPalette.Contrast.LABEL)
                atLeast("$name onFill", r.onFill, r.fill, AppPalette.Contrast.LABEL)
            }
            assertEquals(6, p.series.size)
        }
    }

    @Test fun seriesColoursAreDistinctAndStable() {
        for (t in themes) {
            val p = AppPalette.derive(t)
            val marks = p.series.map { it.mark }
            // No two container colours are the same, so two containers are never confused.
            assertEquals(marks.size, marks.toSet().size, "${t.id}: series colours must differ")
            assertEquals(p.series, AppPalette.derive(t).series, "${t.id}: deterministic")
        }
    }

    @Test fun surfacesAreDistinguishableFromTheBackground() {
        for (t in themes) {
            val p = AppPalette.derive(t)
            for ((name, c) in listOf("sidebar" to p.sidebar, "card" to p.card, "selection" to p.selection, "border" to p.border)) {
                assertNotEquals(p.background, c, "${t.id}: $name must differ from the background")
            }
            assertTrue(p.border.contrastRatio(p.background) > 1.12, "${t.id}: borders must be visible")
            assertTrue(p.selection.contrastRatio(p.background) > 1.08, "${t.id}: selection must be visible")
        }
    }

    @Test fun derivationIsDeterministicAndRackoonDarkMatchesTheDesign() {
        assertEquals(AppPalette.derive(themes[0]), AppPalette.derive(themes[0]))
        val p = AppPalette.derive(themes.first { it.id == "rackoon-dark" })
        assertEquals("#15171C", p.background.hex)
        assertTrue(p.sidebar.luminance - p.background.luminance < 0.02)
        assertTrue(p.sidebar.luminance > p.background.luminance, "sidebar slightly lighter, as in the design")
        assertTrue(p.card.luminance > p.sidebar.luminance - 0.001)
    }
}
