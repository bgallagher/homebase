package com.bgallagher.rackoon.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import com.bgallagher.rackoon.core.AppPalette
import com.bgallagher.rackoon.core.RGB
import com.bgallagher.rackoon.core.ThemeCatalog

fun RGB.color(): Color = Color(red = r, green = g, blue = b)

/** The extra colours Material 3 has no slot for (cards, status, muted text), taken from the palette derived from the theme. */
class RackoonColors(
    val background: Color, val sidebar: Color, val card: Color, val selection: Color, val border: Color,
    val textPrimary: Color, val textSecondary: Color, val textMuted: Color,
    val accent: Color, val accentText: Color, val ok: Color, val warn: Color, val danger: Color, val idle: Color,
)

val LocalRackoon = staticCompositionLocalOf<RackoonColors> { error("RackoonTheme is missing") }

object Rackoon {
    val colors: RackoonColors
        @Composable @ReadOnlyComposable get() = LocalRackoon.current
}

private fun AppPalette.toColors() = RackoonColors(
    background.color(), sidebar.color(), card.color(), selection.color(), border.color(),
    textPrimary.color(), textSecondary.color(), textMuted.color(), accent.color(), accentText.color(),
    ok.color(), warn.color(), danger.color(), idle.color(),
)

private fun AppPalette.toColorScheme() = (if (isDark) darkColorScheme() else lightColorScheme()).copy(
    primary = accent.color(), onPrimary = accentText.color(),
    primaryContainer = selection.color(), onPrimaryContainer = textPrimary.color(),
    background = background.color(), onBackground = textPrimary.color(),
    surface = background.color(), onSurface = textPrimary.color(), onSurfaceVariant = textSecondary.color(),
    surfaceVariant = card.color(), surfaceContainer = sidebar.color(), surfaceContainerHigh = card.color(),
    surfaceContainerHighest = selection.color(), surfaceContainerLow = background.color(), surfaceContainerLowest = background.color(),
    outline = border.color(), outlineVariant = border.color(), error = danger.color(),
    scrim = Color.Black,
)

/** `themeId` is a saved selection: a theme id or `automatic` (Rackoon Dark/Light following the system). */
@Composable
fun RackoonTheme(themeId: String = ThemeCatalog.AUTOMATIC_ID, content: @Composable () -> Unit) {
    val systemDark = isSystemInDarkTheme()
    val palette = remember(themeId, systemDark) {
        val themes = ThemeCatalog.bundled()
        AppPalette.derive(ThemeCatalog.resolve(themeId, systemDark, themes)!!)
    }
    CompositionLocalProvider(LocalRackoon provides palette.toColors()) {
        MaterialTheme(colorScheme = palette.toColorScheme(), content = content)
    }
}
