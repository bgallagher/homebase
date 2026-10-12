package com.bgallagher.rackoon.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.math.pow

/** An 8-bit sRGB colour. Hex parsing lives here so themes stay plain data. */
data class RGB(val r: Int, val g: Int, val b: Int) {
    init {
        require(r in 0..255 && g in 0..255 && b in 0..255) { "channel out of range" }
    }

    val hex: String get() = "#%02X%02X%02X".format(r, g, b)

    /** Linear blend: 0 gives `this`, 1 gives `other`. */
    fun mixed(other: RGB, amount: Double): RGB {
        val k = amount.coerceIn(0.0, 1.0)
        fun mix(a: Int, b: Int) = Math.round(a * (1 - k) + b * k).toInt()
        return RGB(mix(r, other.r), mix(g, other.g), mix(b, other.b))
    }

    /** WCAG contrast ratio, 1 (identical) to 21 (black on white). */
    fun contrastRatio(other: RGB): Double {
        val a = luminance
        val b = other.luminance
        return (maxOf(a, b) + 0.05) / (minOf(a, b) + 0.05)
    }

    /** The best contrast any colour can have against this one (black or white, whichever is further). */
    val bestPossibleContrast: Double get() = maxOf(contrastRatio(BLACK), contrastRatio(WHITE))

    /**
     * `this` if it already has at least `minimum` contrast against `background`; otherwise the closest colour to `this`, moving
     * toward white or black, that does. If even black/white cannot reach it (a mid-grey background), returns the best that can be had.
     */
    fun ensuringContrast(background: RGB, minimum: Double): RGB {
        if (contrastRatio(background) >= minimum) return this
        val target = if (background.contrastRatio(WHITE) >= background.contrastRatio(BLACK)) WHITE else BLACK
        for (step in 1..40) {
            val c = mixed(target, step / 40.0)
            if (c.contrastRatio(background) >= minimum) return c
        }
        return target
    }

    /** WCAG relative luminance, 0 (black) to 1 (white). */
    val luminance: Double
        get() {
            fun lin(c: Int): Double {
                val v = c / 255.0
                return if (v <= 0.03928) v / 12.92 else ((v + 0.055) / 1.055).pow(2.4)
            }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }

    companion object {
        val BLACK = RGB(0, 0, 0)
        val WHITE = RGB(255, 255, 255)
        private val SIX_HEX = Regex("^[0-9a-fA-F]{6}$")

        /**
         * "#RRGGBB" or "RRGGBB" (case-insensitive). Anything else, including 3-digit shorthand, is rejected so a malformed
         * theme file fails loudly instead of rendering a wrong colour.
         */
        fun fromHex(hex: String): RGB? {
            var s = hex.trimBlanks()
            if (s.startsWith("#")) s = s.substring(1)
            if (!SIX_HEX.matches(s)) return null
            val v = s.toInt(16)
            return RGB((v shr 16) and 0xFF, (v shr 8) and 0xFF, v and 0xFF)
        }
    }
}

/** A terminal colour theme. Stored as JSON with hex strings so any platform can read it. */
@Serializable
data class TerminalTheme(
    val id: String,
    val name: String,
    val family: String,
    /** "dark" or "light" */
    val appearance: String,
    val background: String,
    val foreground: String,
    val cursor: String? = null,
    val selection: String? = null,
    /** The 16 ANSI colours: 0-7 normal (black...white), 8-15 bright. */
    val ansi: List<String>,
) {
    val isDark: Boolean get() = appearance == "dark"
    val backgroundRGB: RGB get() = RGB.fromHex(background) ?: RGB(0, 0, 0)
    val foregroundRGB: RGB get() = RGB.fromHex(foreground) ?: RGB(255, 255, 255)
    val ansiRGB: List<RGB> get() = ansi.map { RGB.fromHex(it) ?: RGB(128, 128, 128) }

    /** Cursor colour, falling back to the foreground when the theme has none. */
    val cursorRGB: RGB get() = cursor?.let { RGB.fromHex(it) } ?: foregroundRGB

    /** Selection colour, falling back to the foreground colour; the UI draws it translucent. */
    val selectionRGB: RGB get() = selection?.let { RGB.fromHex(it) } ?: foregroundRGB
}

class ThemeCatalogError(message: String) : Exception("Invalid theme catalogue: $message")

object ThemeCatalog {
    const val DEFAULT_ID = "rackoon-dark"
    const val LIGHT_DEFAULT_ID = "rackoon-light"

    /** Selection id for "follow the system": Rackoon Dark or Light depending on the system appearance. */
    const val AUTOMATIC_ID = "automatic"

    private val json = Json { ignoreUnknownKeys = true }

    /** The theme actually in effect for a saved selection. `automatic` (and any unknown id) follows the system. */
    fun resolve(selection: String, systemIsDark: Boolean, themes: List<TerminalTheme>): TerminalTheme? {
        if (selection != AUTOMATIC_ID) themes.firstOrNull { it.id == selection }?.let { return it }
        val wanted = if (systemIsDark) DEFAULT_ID else LIGHT_DEFAULT_ID
        return themes.firstOrNull { it.id == wanted } ?: themes.firstOrNull { it.id == DEFAULT_ID } ?: themes.firstOrNull()
    }

    /** The 45 bundled themes (the shared themes.json, copied into this module's resources at build time). */
    fun bundled(): List<TerminalTheme> {
        val text = ThemeCatalog::class.java.getResourceAsStream("/spec/themes.json")?.use { it.readBytes().toString(Charsets.UTF_8) }
            ?: throw ThemeCatalogError("themes.json is missing from the module resources")
        return load(text)
    }

    /** Decodes and validates a theme list: unique ids, 16 valid ANSI colours, valid hex everywhere, and an appearance label that agrees with the background's luminance. */
    fun load(text: String): List<TerminalTheme> {
        val themes = try {
            json.decodeFromString<List<TerminalTheme>>(text)
        } catch (e: Exception) {
            throw ThemeCatalogError("not valid theme JSON: ${e.message}")
        }
        validate(themes)
        return themes
    }

    fun validate(themes: List<TerminalTheme>) {
        val seen = HashSet<String>()
        for (t in themes) {
            fun bad(m: String) = ThemeCatalogError("${t.id}: $m")
            if (t.id.isEmpty() || !seen.add(t.id)) throw bad("missing or duplicate id")
            if (t.appearance != "dark" && t.appearance != "light") throw bad("appearance must be dark or light")
            val bg = RGB.fromHex(t.background) ?: throw bad("bad background")
            if (RGB.fromHex(t.foreground) == null) throw bad("bad foreground")
            if (t.cursor != null && RGB.fromHex(t.cursor) == null) throw bad("bad cursor")
            if (t.selection != null && RGB.fromHex(t.selection) == null) throw bad("bad selection")
            if (t.ansi.size != 16) throw bad("needs exactly 16 ANSI colours, has ${t.ansi.size}")
            t.ansi.forEachIndexed { i, c -> if (RGB.fromHex(c) == null) throw bad("bad ANSI colour $i: $c") }
            val looksDark = bg.luminance < 0.4
            if (looksDark != t.isDark) throw bad("labelled ${t.appearance} but the background is ${if (looksDark) "dark" else "light"}")
        }
        if (DEFAULT_ID !in seen || LIGHT_DEFAULT_ID !in seen) {
            throw ThemeCatalogError("$DEFAULT_ID and $LIGHT_DEFAULT_ID must both exist (Automatic needs them)")
        }
    }
}
