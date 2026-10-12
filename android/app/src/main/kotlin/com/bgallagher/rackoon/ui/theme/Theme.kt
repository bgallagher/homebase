package com.bgallagher.rackoon.ui.theme

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import com.bgallagher.rackoon.core.TerminalTheme
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

/** The terminal theme behind the current app palette, so terminals and screens always agree. */
val LocalTerminalTheme = staticCompositionLocalOf<TerminalTheme> { error("RackoonTheme is missing") }

/** `themeId` is a saved selection: a theme id or `automatic` (Rackoon Dark/Light following the system). */
@Composable
fun RackoonTheme(themeId: String = ThemeCatalog.AUTOMATIC_ID, content: @Composable () -> Unit) {
    val systemDark = isSystemInDarkTheme()
    val theme = remember(themeId, systemDark) { ThemeCatalog.resolve(themeId, systemDark, ThemeCatalog.bundled())!! }
    val palette = remember(theme) { AppPalette.derive(theme) }
    // Edge-to-edge picks status and navigation bar icon colours from the SYSTEM mode; follow the chosen theme instead.
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as? Activity)?.window ?: return@SideEffect
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = !palette.isDark
                isAppearanceLightNavigationBars = !palette.isDark
            }
        }
    }
    CompositionLocalProvider(LocalRackoon provides palette.toColors(), LocalTerminalTheme provides theme) {
        MaterialTheme(colorScheme = palette.toColorScheme(), content = content)
    }
}
