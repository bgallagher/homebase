package com.bgallagher.rackoon.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.clickable
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.bgallagher.rackoon.AppViewModel
import com.bgallagher.rackoon.core.AptAction
import com.bgallagher.rackoon.core.PendingUpdate
import com.bgallagher.rackoon.core.UpdatesPresentation
import com.bgallagher.rackoon.core.UpdatesSnapshot
import com.bgallagher.rackoon.ui.theme.Rackoon
import com.bgallagher.rackoon.ui.theme.RackoonIcons

/** The Updates page (More > Updates): what apt says is waiting, with Refresh Lists, Install All and Install Security Updates. */
@Composable
fun UpdatesScreen(vm: AppViewModel, readOnly: Boolean, onBack: () -> Unit) {
    BackHandler(onBack = onBack)
    val c = Rackoon.colors
    val state by vm.updates.collectAsStateWithLifecycle()
    val loading by vm.updatesLoading.collectAsStateWithLifecycle()
    val working by vm.updatesWorking.collectAsStateWithLifecycle()
    val output by vm.updatesOutput.collectAsStateWithLifecycle()
    var securityOnly by remember { mutableStateOf(false) }
    val snapshot = state.snapshot
    val packages = remember(snapshot) { UpdatesPresentation.sorted(snapshot?.packages.orEmpty()) }
    val now = System.currentTimeMillis() / 1000

    Column(Modifier.fillMaxSize().background(c.background).statusBarsPadding()) {
        Row(Modifier.height(64.dp).padding(start = 4.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconTap(RackoonIcons.ChevronLeft, "Back to More", c.textPrimary, onBack)
            Text("Updates", fontSize = 18.sp, fontWeight = FontWeight.Medium, color = c.textPrimary, modifier = Modifier.weight(1f))
            if (loading) Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = c.accent) }
            else IconTap(RackoonIcons.Refresh, "Read the update list again", if (working == null) c.textPrimary else c.textMuted, { vm.loadUpdates() })
        }
        if (readOnly) ReadOnlyBanner(onTurnOff = vm::toggleReadOnly)
        val run = output
        if (run != null) {
            // Apt's own progress, in a terminal, like the stack Output tab. The list below comes back when it is closed.
            Box(Modifier.weight(1f)) { ActionOutputPanel(run, onCancel = vm::cancelUpdatesOutput, onClose = vm::closeUpdatesOutput) }
        } else LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 16.dp, end = 16.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item {
                if (snapshot != null) {
                    Text(UpdatesPresentation.subtitle(snapshot), fontSize = 14.sp, color = if (snapshot.securityCount > 0) c.warn else c.textSecondary)
                    UpdatesPresentation.staleness(snapshot, now)?.let { Text(it, fontSize = 12.sp, color = c.warn, modifier = Modifier.padding(top = 4.dp)) }
                } else if (state.error == null) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        StatusDot(c.warn); Text("Reading updates…", color = c.textSecondary, fontSize = 13.sp)
                    }
                }
            }
            state.error?.let { item { Banner(it, c.danger) } }
            state.actionError?.let { item { Banner(it, c.danger) } }
            if (snapshot != null) {
                if (snapshot.rebootRequired) item { Banner("A reboot is needed to finish applying earlier updates.", c.warn) }
                item { Summary(snapshot, now) }
                item { Actions(vm, packages, readOnly, working) }
                if (packages.isEmpty()) item {
                    RCard(Modifier.fillMaxWidth()) {
                        Text("No updates are waiting. This list comes from the server's last package refresh.", color = c.textSecondary, lineHeight = 20.sp, modifier = Modifier.padding(16.dp))
                    }
                } else {
                    item { PackageHeader(securityOnly) { securityOnly = it } }
                    val shown = if (securityOnly) packages.filter { it.isSecurity } else packages
                    if (shown.isEmpty()) item { Text("No security updates.", color = c.textMuted, modifier = Modifier.padding(horizontal = 4.dp)) }
                    items(shown, key = { it.id }) { PackageRow(it) }
                }
                if (snapshot.held.isNotEmpty()) item {
                    RCard(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text("Held back", fontWeight = FontWeight.SemiBold, color = c.textPrimary)
                            Text("These packages are pinned with apt-mark hold, so updates skip them: ${snapshot.held.joinToString(", ")}.", fontSize = 13.sp, lineHeight = 19.sp, color = c.textSecondary)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Banner(text: String, color: Color) {
    Text(
        text, color = color, fontSize = 13.sp, lineHeight = 19.sp,
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(color.copy(alpha = 0.12f)).padding(12.dp),
    )
}

@Composable
private fun Summary(s: UpdatesSnapshot, now: Long) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Tile("Available", "${s.packages.size}", null, Modifier.weight(1f))
            Tile("Security", "${s.securityCount}", if (s.securityCount > 0) Rackoon.colors.warn else Rackoon.colors.ok, Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Tile("Held back", "${s.held.size}", null, Modifier.weight(1f))
            Tile("Lists refreshed", UpdatesPresentation.refreshedText(s, now), null, Modifier.weight(1f), small = true)
        }
    }
}

@Composable
private fun Tile(title: String, value: String, tint: Color?, modifier: Modifier, small: Boolean = false) {
    val c = Rackoon.colors
    RCard(modifier) {
        Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title.uppercase(), fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.6.sp, color = c.textMuted)
            Text(value, fontSize = if (small) 16.sp else 26.sp, fontWeight = FontWeight.Bold, color = tint ?: c.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.height(32.dp))
        }
    }
}

@Composable
private fun Actions(vm: AppViewModel, packages: List<PendingUpdate>, readOnly: Boolean, working: String?) {
    val c = Rackoon.colors
    val blocked = vm.aptBlockedReason()
    val security = vm.securityAction()
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (working != null) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = c.accent)
            Text(working, color = c.textSecondary, fontSize = 13.sp)
        }
        PrimaryButton("Install Security Updates", { security?.let(vm::requestApt) }, Modifier.fillMaxWidth(), enabled = blocked == null && security != null)
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            SecondaryButton("Install All", { vm.requestApt(AptAction.UpgradeAll) }, Modifier.weight(1f), enabled = blocked == null && packages.isNotEmpty())
            SecondaryButton("Refresh Lists", { vm.requestApt(AptAction.Refresh) }, Modifier.weight(1f), enabled = blocked == null)
        }
        // The reason a button is off, once, instead of leaving it greyed out unexplained.
        (blocked ?: UpdatesPresentation.installSecurityHint(packages, readOnly).takeIf { security == null && packages.any { it.isSecurity } })?.let {
            Text(it, fontSize = 12.sp, color = c.textMuted)
        }
    }
}

@Composable
private fun PackageHeader(securityOnly: Boolean, onPick: (Boolean) -> Unit) {
    val c = Rackoon.colors
    val shape = RoundedCornerShape(12.dp)
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("Packages", fontWeight = FontWeight.SemiBold, color = c.textPrimary, modifier = Modifier.weight(1f))
        Row(Modifier.clip(shape).border(1.dp, c.border, shape)) {
            listOf("All" to false, "Security" to true).forEach { (label, value) ->
                val on = securityOnly == value
                Box(Modifier.height(36.dp).background(if (on) c.selection else Color.Transparent).clickable { onPick(value) }.padding(horizontal = 14.dp), contentAlignment = Alignment.Center) {
                    Text(label, fontSize = 13.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal, color = if (on) c.textPrimary else c.textSecondary)
                }
            }
        }
    }
}

@Composable
private fun PackageRow(pkg: PendingUpdate) {
    val c = Rackoon.colors
    RCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(pkg.name, fontWeight = FontWeight.Medium, color = c.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                if (pkg.isSecurity) Text("Security", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = c.warn, modifier = Modifier.clip(RoundedCornerShape(6.dp)).background(c.warn.copy(alpha = 0.14f)).padding(horizontal = 6.dp, vertical = 2.dp))
            }
            Text(pkg.suite, fontSize = 12.sp, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                (pkg.oldVersion?.let { "$it → " } ?: "") + pkg.newVersion, fontFamily = MonoFamily, fontSize = 12.sp, color = c.textSecondary,
                maxLines = 1, overflow = TextOverflow.MiddleEllipsis,
            )
        }
    }
}
