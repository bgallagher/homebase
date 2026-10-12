package com.bgallagher.rackoon.ui

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.bgallagher.rackoon.AppViewModel
import com.bgallagher.rackoon.core.Server
import com.bgallagher.rackoon.core.ThemeCatalog
import com.bgallagher.rackoon.terminal.TabState
import com.bgallagher.rackoon.terminal.TerminalTab
import com.bgallagher.rackoon.ui.theme.Rackoon
import com.bgallagher.rackoon.ui.theme.RackoonIcons
import org.connectbot.terminal.Terminal

@Composable
fun TerminalScreen(vm: AppViewModel, server: Server, readOnly: Boolean, onTurnOffReadOnly: () -> Unit) {
    val c = Rackoon.colors
    if (readOnly) {
        // Read-only gates the terminal: a shell can change anything, so it stays off until the switch is turned off on purpose.
        Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(RackoonIcons.Lock, null, tint = c.textMuted, modifier = Modifier.size(40.dp))
            Text("Terminal is off", fontSize = 20.sp, fontWeight = FontWeight.Medium, color = c.textPrimary, modifier = Modifier.padding(top = 12.dp))
            Text(
                "Read-only is on. A shell can change anything on the server, so turn Read-only off to open a session.",
                color = c.textSecondary, lineHeight = 21.sp, modifier = Modifier.padding(top = 6.dp, bottom = 20.dp),
            )
            PrimaryButton("Turn off Read-only", onTurnOffReadOnly)
        }
        return
    }

    val systemDark = isSystemInDarkTheme()
    val theme = remember(systemDark) { ThemeCatalog.resolve(ThemeCatalog.AUTOMATIC_ID, systemDark, ThemeCatalog.bundled())!! }
    val all by vm.terminals.tabs.collectAsStateWithLifecycle()
    val selectedIds by vm.terminals.selected.collectAsStateWithLifecycle()
    val tabs = all[server.id].orEmpty()
    val current = tabs.firstOrNull { it.id == selectedIds[server.id] } ?: tabs.lastOrNull()

    // Android 13+ needs a runtime grant to show the "sessions open" notification; the sessions work either way.
    val askNotifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    val context = LocalContext.current
    LaunchedEffect(server.id) {
        if (all[server.id].isNullOrEmpty()) {
            if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
            vm.openTerminal(server, theme)
        }
    }
    LaunchedEffect(theme) { vm.terminals.applyTheme(theme) }

    Column(Modifier.fillMaxSize().imePadding()) {
        TabStrip(tabs, current, onSelect = { vm.terminals.select(server.id, it) }, onClose = { vm.terminals.close(server.id, it) }, onNew = { vm.openTerminal(server, theme) })
        if (current == null) {
            Box(Modifier.weight(1f))
        } else key(current.id) {
            val state by current.state.collectAsStateWithLifecycle()
            Box(Modifier.weight(1f).fillMaxWidth().background(Color(theme.backgroundRGB.r, theme.backgroundRGB.g, theme.backgroundRGB.b))) {
                Terminal(
                    current.emulator, Modifier.fillMaxSize(), keyboardEnabled = state is TabState.Live,
                    backgroundColor = Color(theme.backgroundRGB.r, theme.backgroundRGB.g, theme.backgroundRGB.b),
                    foregroundColor = Color(theme.foregroundRGB.r, theme.foregroundRGB.g, theme.foregroundRGB.b),
                )
                StateOverlay(state, current, onCloseTab = { vm.terminals.close(server.id, current) }, modifier = Modifier.align(Alignment.BottomCenter))
            }
            ExtraKeys(current)
        }
    }
}

@Composable
private fun TabStrip(tabs: List<TerminalTab>, current: TerminalTab?, onSelect: (TerminalTab) -> Unit, onClose: (TerminalTab) -> Unit, onNew: () -> Unit) {
    val c = Rackoon.colors
    Row(
        Modifier.fillMaxWidth().height(44.dp).horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        tabs.forEach { tab ->
            val on = tab.id == current?.id
            val state by tab.state.collectAsStateWithLifecycle()
            val shape = RoundedCornerShape(10.dp)
            Row(
                Modifier.height(34.dp).clip(shape).background(if (on) c.selection else c.card).border(1.dp, if (on) c.accent else c.border, shape)
                    .clickable { onSelect(tab) }.padding(start = 12.dp, end = 4.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                StatusDot(when (state) { TabState.Live -> c.ok; is TabState.Ended -> c.danger; else -> c.warn }, 7)
                Text(tab.title, fontSize = 13.sp, color = c.textPrimary, maxLines = 1, modifier = Modifier.widthIn(max = 120.dp))
                Box(Modifier.size(30.dp).clip(RoundedCornerShape(15.dp)).clickable { onClose(tab) }, contentAlignment = Alignment.Center) {
                    Text("✕", fontSize = 12.sp, color = c.textMuted)
                }
            }
        }
        Box(
            Modifier.size(34.dp).clip(RoundedCornerShape(10.dp)).border(1.dp, c.border, RoundedCornerShape(10.dp)).clickable(onClick = onNew),
            contentAlignment = Alignment.Center,
        ) { Text("+", fontSize = 18.sp, color = c.textSecondary) }
    }
}

@Composable
private fun StateOverlay(state: TabState, tab: TerminalTab, onCloseTab: () -> Unit, modifier: Modifier) {
    val c = Rackoon.colors
    val (title, body, danger) = when (state) {
        TabState.Live -> return
        TabState.Connecting -> Triple("Connecting…", "Waiting for Tailscale or the network if this takes a moment.", false)
        is TabState.Reconnecting -> Triple("Connection lost", "Reconnecting in ${state.seconds} s · attempt ${state.attempt} of ${state.of}. Your scrollback is kept. Long jobs belong in tmux.", false)
        is TabState.Ended -> Triple(state.message, "", true)
    }
    RCard(modifier.padding(12.dp).fillMaxWidth(), borderColor = if (danger) c.danger else c.border) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, fontWeight = FontWeight.SemiBold, color = if (danger) c.danger else c.textPrimary)
            if (body.isNotEmpty()) Text(body, fontSize = 13.sp, color = c.textSecondary, lineHeight = 18.sp)
            when (state) {
                is TabState.Reconnecting -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PrimaryButton("Reconnect now", tab::reconnectNow)
                    SecondaryButton("Cancel", onCloseTab)
                }
                is TabState.Ended -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PrimaryButton("Reconnect", tab::reconnectNow)
                    SecondaryButton("Close tab", onCloseTab)
                }
                else -> {}
            }
        }
    }
}

/** Keys a phone keyboard lacks. Ctrl and Alt are sticky: they apply to the next key and release. */
@Composable
private fun ExtraKeys(tab: TerminalTab) {
    val c = Rackoon.colors
    val ctrl by tab.ctrl.collectAsStateWithLifecycle()
    val alt by tab.alt.collectAsStateWithLifecycle()
    Row(
        Modifier.fillMaxWidth().background(c.sidebar).horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Key("Esc") { tab.sendText("\u001B") }
        Key("Tab") { tab.sendText("\t") }
        Key("Ctrl", active = ctrl) { tab.toggleCtrl() }
        Key("Alt", active = alt) { tab.toggleAlt() }
        Key("↑") { tab.sendText("\u001B[A") }
        Key("↓") { tab.sendText("\u001B[B") }
        Key("←") { tab.sendText("\u001B[D") }
        Key("→") { tab.sendText("\u001B[C") }
        Key("|") { tab.sendText("|") }
        Key("~") { tab.sendText("~") }
        Key("/") { tab.sendText("/") }
        Key("-") { tab.sendText("-") }
        Key("^C") { tab.sendText("\u0003") }
        Key("^D") { tab.sendText("\u0004") }
    }
}

@Composable
private fun Key(label: String, active: Boolean = false, onClick: () -> Unit) {
    val c = Rackoon.colors
    val shape = RoundedCornerShape(8.dp)
    Box(
        Modifier.height(40.dp).widthIn(min = 44.dp).clip(shape).background(if (active) c.accent else c.card).border(1.dp, c.border, shape)
            .clickable(onClick = onClick).padding(horizontal = 10.dp),
        contentAlignment = Alignment.Center,
    ) { Text(label, fontSize = 14.sp, fontFamily = FontFamily.Monospace, color = if (active) c.accentText else c.textPrimary) }
}
