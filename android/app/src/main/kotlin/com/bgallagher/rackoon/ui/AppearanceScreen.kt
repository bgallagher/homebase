package com.bgallagher.rackoon.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bgallagher.rackoon.core.RGB
import com.bgallagher.rackoon.core.TerminalTheme
import com.bgallagher.rackoon.core.ThemeCatalog
import com.bgallagher.rackoon.ui.theme.Rackoon
import com.bgallagher.rackoon.ui.theme.RackoonIcons

private fun RGB.c() = Color(r, g, b)

/** More > Appearance: Automatic plus the 45 bundled themes. One choice themes the whole app and the terminal. */
@Composable
fun AppearanceScreen(selectedId: String, onPick: (String) -> Unit, onBack: () -> Unit) {
    BackHandler(onBack = onBack)
    val themes = remember { ThemeCatalog.bundled() }
    val c = Rackoon.colors
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().height(64.dp).padding(start = 4.dp, end = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            IconTap(RackoonIcons.ChevronLeft, "Back", c.textPrimary, onBack)
            Text("Appearance", fontSize = 20.sp, fontWeight = FontWeight.Medium, color = c.textPrimary)
        }
        LazyColumn(Modifier.fillMaxWidth().weight(1f), contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item {
                ThemeRow("Automatic", "Rackoon Dark or Light, following the system", selectedId == ThemeCatalog.AUTOMATIC_ID, null) { onPick(ThemeCatalog.AUTOMATIC_ID) }
            }
            items(themes, key = { it.id }) { t ->
                ThemeRow(t.name, t.family.takeIf { it.isNotBlank() && it != t.name } ?: if (t.isDark) "Dark" else "Light", selectedId == t.id, t) { onPick(t.id) }
            }
            item { Box(Modifier.navigationBarsPadding().height(16.dp)) }
        }
    }
}

@Composable
private fun ThemeRow(name: String, note: String, selected: Boolean, theme: TerminalTheme?, onClick: () -> Unit) {
    val c = Rackoon.colors
    val shape = RoundedCornerShape(12.dp)
    Row(
        Modifier.fillMaxWidth().clip(shape).background(c.card).border(if (selected) 2.dp else 1.dp, if (selected) c.accent else c.border, shape)
            .clickable(onClick = onClick).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Swatch(theme)
        Column(Modifier.weight(1f)) {
            Text(name, fontWeight = FontWeight.Medium, color = c.textPrimary)
            Text(note, fontSize = 12.sp, color = c.textMuted)
        }
        if (selected) Text("✓", color = c.accent, fontSize = 18.sp, fontWeight = FontWeight.Bold)
    }
}

/** A miniature terminal: the theme's own background with its red, green, yellow and blue (null: split light/dark for Automatic). */
@Composable
private fun Swatch(theme: TerminalTheme?) {
    val shape = RoundedCornerShape(8.dp)
    if (theme == null) {
        Row(Modifier.size(width = 64.dp, height = 40.dp).clip(shape).border(1.dp, Rackoon.colors.border, shape)) {
            Box(Modifier.weight(1f).fillMaxSize().background(Color(0xFF14161C)))
            Box(Modifier.weight(1f).fillMaxSize().background(Color(0xFFF5F5F7)))
        }
        return
    }
    Row(
        Modifier.size(width = 64.dp, height = 40.dp).clip(shape).background(theme.backgroundRGB.c()).border(1.dp, Rackoon.colors.border, shape),
        horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically,
    ) {
        val ansi = theme.ansiRGB
        listOf(1, 2, 3, 4).forEach { i -> Box(Modifier.size(9.dp).clip(CircleShape).background(ansi[i].c())) }
    }
}
