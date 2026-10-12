package com.bgallagher.rackoon.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.border
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.bgallagher.rackoon.AppViewModel
import com.bgallagher.rackoon.Issue
import com.bgallagher.rackoon.OverviewUi
import com.bgallagher.rackoon.Tab
import com.bgallagher.rackoon.core.Server
import com.bgallagher.rackoon.ui.theme.Rackoon
import com.bgallagher.rackoon.ui.theme.RackoonIcons

@Composable
fun RackoonRoot(vm: AppViewModel) {
    val firstRun by vm.firstRun.collectAsStateWithLifecycle()
    val servers by vm.servers.collectAsStateWithLifecycle()
    val selected by vm.selectedServer.collectAsStateWithLifecycle()
    val add by vm.add.collectAsStateWithLifecycle()
    val readOnly by vm.readOnly.collectAsStateWithLifecycle()
    val tab by vm.tab.collectAsStateWithLifecycle()
    val overview by vm.overview.collectAsStateWithLifecycle()
    val switcher by vm.switcher.collectAsStateWithLifecycle()

    Box(Modifier.fillMaxSize().background(Rackoon.colors.background)) {
        when {
            add != null -> AddServerScreen(add!!, vm::editAdd, vm::submitAdd, vm::cancelAdd, vm::trustAndConnect, vm::declineTrust)
            firstRun -> FirstRunScreen(vm::dismissFirstRun)
            selected == null -> Welcome(onAdd = vm::startAdd)
            else -> Shell(vm, selected!!, overview, tab, readOnly)
        }
        if (switcher) ServerSwitcher(servers, selected, overview, onPick = vm::select, onAdd = vm::startAdd, onRemove = vm::remove, onDismiss = { vm.showSwitcher(false) })
    }
}

@Composable
private fun Welcome(onAdd: () -> Unit) {
    Column(Modifier.fillMaxSize().statusBarsPadding().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Text("🦝", fontSize = 56.sp)
        Text("Add your first server", fontSize = 24.sp, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary, modifier = Modifier.padding(top = 16.dp))
        Text(
            "Rackoon connects over SSH and runs standard commands. Nothing is installed on the server.",
            color = Rackoon.colors.textSecondary, lineHeight = 21.sp, modifier = Modifier.padding(top = 8.dp, bottom = 24.dp),
        )
        PrimaryButton("Add server", onAdd, Modifier.fillMaxWidth())
    }
}

@Composable
private fun Shell(vm: AppViewModel, server: Server, overview: OverviewUi, tab: Tab, readOnly: Boolean) {
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        TopBar(server.name, statusColor(overview), readOnly, onSwitcher = { vm.showSwitcher(true) }, onReadOnly = vm::toggleReadOnly)
        Box(Modifier.weight(1f)) {
            when (tab) {
                Tab.Overview -> {
                    val lifecycle = LocalLifecycleOwner.current.lifecycle
                    // Poll only while the screen is visible: no background work, no battery cost when the phone is in a pocket.
                    LaunchedEffect(server.id) { lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { vm.pollWhileVisible() } }
                    OverviewScreen(overview, onRefresh = vm::refreshNow, onTrustFirstKey = vm::trustPresented, onBack = { vm.showSwitcher(true) })
                }
                Tab.Terminal -> TerminalScreen(vm, server, readOnly, onTurnOffReadOnly = vm::toggleReadOnly)
                Tab.More -> MoreScreen(onServers = { vm.showSwitcher(true) }, onAdd = vm::startAdd, highlight = vm.highlightOutput.collectAsStateWithLifecycle().value, onHighlight = vm::setHighlight)
            }
        }
        BottomBar(tab, vm::showTab)
    }
}

@Composable
private fun statusColor(ui: OverviewUi) = when (ui) {
    OverviewUi.Connecting -> Rackoon.colors.warn
    is OverviewUi.Ready -> Rackoon.colors.ok
    is OverviewUi.Failed -> Rackoon.colors.danger
}

@Composable
private fun TopBar(name: String, dot: androidx.compose.ui.graphics.Color, readOnly: Boolean, onSwitcher: () -> Unit, onReadOnly: () -> Unit) {
    Row(Modifier.fillMaxWidth().height(64.dp).padding(start = 8.dp, end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier.height(48.dp).clip(RoundedCornerShape(24.dp)).clickable(onClick = onSwitcher).padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            StatusDot(dot)
            Text(name, fontSize = 18.sp, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary)
            Icon(RackoonIcons.ChevronDown, "Switch server", tint = Rackoon.colors.textSecondary, modifier = Modifier.size(18.dp))
        }
        Spacer(Modifier.weight(1f))
        ReadOnlyChip(readOnly, onReadOnly)
    }
}

@Composable
fun ReadOnlyChip(on: Boolean, onClick: () -> Unit, small: Boolean = false) {
    val c = Rackoon.colors
    val shape = RoundedCornerShape(if (small) 8.dp else 10.dp)
    Row(
        Modifier.height(if (small) 28.dp else 36.dp).clip(shape)
            .then(if (on) Modifier.background(c.accent) else Modifier.border(BorderStroke(1.dp, c.border), shape))
            .clickable(onClick = onClick).padding(horizontal = if (small) 10.dp else 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(RackoonIcons.Lock, null, tint = if (on) c.accentText else c.textSecondary, modifier = Modifier.size(if (small) 12.dp else 14.dp))
        Text(if (on) "Read-only" else "Read-only off", color = if (on) c.accentText else c.textSecondary, fontSize = if (small) 12.sp else 13.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun BottomBar(tab: Tab, onTab: (Tab) -> Unit) {
    val c = Rackoon.colors
    NavigationBar(containerColor = c.sidebar, modifier = Modifier.navigationBarsPaddingFix()) {
        listOf(Tab.Overview to ("Overview" to RackoonIcons.Overview), Tab.Terminal to ("Terminal" to RackoonIcons.Terminal), Tab.More to ("More" to RackoonIcons.More)).forEach { (t, label) ->
            NavigationBarItem(
                selected = tab == t, onClick = { onTab(t) }, icon = { Icon(label.second, null) }, label = { Text(label.first) },
                colors = NavigationBarItemDefaults.colors(
                    selectedIconColor = c.accent, selectedTextColor = c.textPrimary, unselectedIconColor = c.textSecondary,
                    unselectedTextColor = c.textSecondary, indicatorColor = c.accent.copy(alpha = 0.2f),
                ),
            )
        }
    }
}

// NavigationBar already insets for the system bar; this keeps the call site readable.
private fun Modifier.navigationBarsPaddingFix(): Modifier = this

@Composable
private fun Placeholder(title: String, body: String) {
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(RackoonIcons.Terminal, null, tint = Rackoon.colors.textMuted, modifier = Modifier.size(40.dp))
        Text(title, fontSize = 20.sp, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary, modifier = Modifier.padding(top = 12.dp))
        Text(body, color = Rackoon.colors.textSecondary, lineHeight = 21.sp, modifier = Modifier.padding(top = 6.dp))
    }
}

@Composable
private fun MoreScreen(onServers: () -> Unit, onAdd: () -> Unit, highlight: Boolean, onHighlight: (Boolean) -> Unit) {
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        RCard(Modifier.fillMaxWidth()) {
            Column {
                MoreRow("Servers", "Switch, add or remove", onServers)
                Box(Modifier.fillMaxWidth().height(1.dp).background(Rackoon.colors.border))
                MoreRow("Add server", "Connect to another machine", onAdd)
                Box(Modifier.fillMaxWidth().height(1.dp).background(Rackoon.colors.border))
                MoreRow("Appearance", "Themes arrive in the next build", null)
                Box(Modifier.fillMaxWidth().height(1.dp).background(Rackoon.colors.border))
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Highlight terminal output", fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary)
                        Text("Colour errors, warnings, IP addresses and high percentages", fontSize = 12.sp, color = Rackoon.colors.textMuted)
                    }
                    androidx.compose.material3.Switch(highlight, onHighlight)
                }
            }
        }
        Text("Rackoon 0.1.0-alpha.1 · developed by Brian Gallagher", color = Rackoon.colors.textMuted, fontSize = 12.sp)
    }
}

@Composable
private fun MoreRow(title: String, subtitle: String, onClick: (() -> Unit)?) {
    Row(Modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier).padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.Medium, color = if (onClick != null) Rackoon.colors.textPrimary else Rackoon.colors.textMuted)
            Text(subtitle, fontSize = 12.sp, color = Rackoon.colors.textMuted)
        }
        if (onClick != null) Icon(RackoonIcons.ChevronRight, null, tint = Rackoon.colors.textMuted, modifier = Modifier.size(18.dp))
    }
}

@OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun ServerSwitcher(servers: List<Server>, selected: Server?, overview: OverviewUi, onPick: (Server) -> Unit, onAdd: () -> Unit, onRemove: (Server) -> Unit, onDismiss: () -> Unit) {
    var removing by remember { mutableStateOf<Server?>(null) }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(), containerColor = Rackoon.colors.sidebar, scrimColor = androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.55f)) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 28.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Servers", fontSize = 20.sp, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary, modifier = Modifier.padding(start = 8.dp, top = 8.dp, bottom = 8.dp))
            servers.forEach { s ->
                val isSel = s.id == selected?.id
                val (dot, note, noteColor) = if (isSel) when (overview) {
                    OverviewUi.Connecting -> Triple(Rackoon.colors.warn, "Connecting…", Rackoon.colors.warn)
                    is OverviewUi.Ready -> Triple(Rackoon.colors.ok, "Connected · ${overview.state.overview?.os?.prettyName ?: ""}", Rackoon.colors.textSecondary)
                    is OverviewUi.Failed -> Triple(Rackoon.colors.danger, failureNote(overview.issue), Rackoon.colors.danger)
                } else Triple(Rackoon.colors.idle, "${s.user ?: "root"}@${s.host}", Rackoon.colors.textMuted)
                Row(
                    Modifier.fillMaxWidth().heightMin(64).clip(RoundedCornerShape(14.dp)).background(if (isSel) Rackoon.colors.selection else androidx.compose.ui.graphics.Color.Transparent)
                        .combinedClickable(onClick = { onPick(s) }, onLongClick = { removing = s }).padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    StatusDot(dot, 10)
                    Column(Modifier.weight(1f)) {
                        Text(s.name, fontSize = 16.sp, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary)
                        Text(note, fontSize = 13.sp, color = noteColor)
                    }
                    if (isSel) Text("Current", fontSize = 13.sp, color = Rackoon.colors.textMuted)
                }
            }
            Row(
                Modifier.fillMaxWidth().heightMin(56).padding(top = 4.dp).clip(RoundedCornerShape(14.dp)).border(BorderStroke(1.dp, Rackoon.colors.border), RoundedCornerShape(14.dp))
                    .clickable(onClick = onAdd).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Icon(RackoonIcons.Plus, null, tint = Rackoon.colors.accent, modifier = Modifier.size(20.dp))
                Text("Add server", color = Rackoon.colors.accent, fontWeight = FontWeight.Medium)
            }
            Text("Touch and hold a server to remove it.", fontSize = 12.sp, color = Rackoon.colors.textMuted, modifier = Modifier.padding(start = 8.dp, top = 6.dp))
        }
    }
    removing?.let { s ->
        AlertDialog(
            onDismissRequest = { removing = null }, containerColor = Rackoon.colors.sidebar,
            title = { Text("Remove ${s.name}?", color = Rackoon.colors.textPrimary) },
            text = { Text("It is removed from this phone, along with its trusted host key. Nothing changes on the server.", color = Rackoon.colors.textSecondary) },
            confirmButton = { TextButton(onClick = { onRemove(s); removing = null }) { Text("Remove", color = Rackoon.colors.danger) } },
            dismissButton = { TextButton(onClick = { removing = null }) { Text("Cancel", color = Rackoon.colors.textPrimary) } },
        )
    }
}

private fun Modifier.heightMin(dp: Int): Modifier = this.then(Modifier.defaultMinSize(minHeight = dp.dp))

private fun failureNote(issue: Issue) = when (issue) {
    is Issue.Unreachable -> "Can't reach it"
    is Issue.AuthFailed -> "Sign-in refused"
    is Issue.KeyChanged -> "Host key changed"
    is Issue.KeyUnknown -> "Host key not trusted"
    is Issue.Other -> "Connection failed"
}
