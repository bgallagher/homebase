package com.bgallagher.rackoon.ui

import android.content.ClipData
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bgallagher.rackoon.Issue
import com.bgallagher.rackoon.OverviewUi
import com.bgallagher.rackoon.core.AttentionItem
import com.bgallagher.rackoon.core.Overview
import com.bgallagher.rackoon.core.ServerState
import com.bgallagher.rackoon.ui.theme.Rackoon
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun OverviewScreen(ui: OverviewUi, wide: Boolean, onRefresh: () -> Unit, onTrustFirstKey: (Issue.KeyUnknown) -> Unit, onBack: () -> Unit, onOpenTerminal: () -> Unit) {
    when (ui) {
        OverviewUi.Connecting -> Loading()
        is OverviewUi.Failed -> when (val issue = ui.issue) {
            is Issue.KeyChanged -> HostKeyChangedScreen(issue.host, issue.trusted, issue.presented, onBack)
            is Issue.KeyUnknown -> TrustSheet(issue.host, issue.presented, onTrust = { onTrustFirstKey(issue) }, onCancel = onBack)
            else -> Unavailable(issue, onRefresh)
        }
        is OverviewUi.Ready -> Ready(ui.state, wide, onRefresh, onOpenTerminal)
    }
}

@Composable
private fun Loading() {
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            StatusDot(Rackoon.colors.warn)
            Text("Connecting…", color = Rackoon.colors.textSecondary)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Placeholder(Modifier.weight(1f).height(112.dp))
            Placeholder(Modifier.weight(1f).height(112.dp))
        }
        Placeholder(Modifier.fillMaxWidth().height(112.dp))
        Placeholder(Modifier.fillMaxWidth().height(220.dp))
        Text(
            "Opening an SSH session. The first connection after Tailscale has been idle can take a few seconds.",
            color = Rackoon.colors.textMuted, fontSize = 12.sp, modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun Placeholder(modifier: Modifier) {
    RCard(modifier) { Box(Modifier.fillMaxSize()) }
}

@Composable
private fun Unavailable(issue: Issue, onRetry: () -> Unit) {
    val (title, body) = when (issue) {
        is Issue.Unreachable -> "Can't reach this server" to (issue.detail + ". " + if (!vpnActive(LocalContext.current)) "No VPN is active on this phone. If this server is on your tailnet, open Tailscale and connect, then try again." else "Check that the address is right and the server is running.")
        is Issue.AuthFailed -> "Sign-in was refused" to issue.detail
        is Issue.Other -> "Something went wrong" to issue.detail
        else -> "Unavailable" to ""
    }
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        RCard(Modifier.fillMaxWidth(), borderColor = Rackoon.colors.danger) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    StatusDot(Rackoon.colors.danger, 10)
                    Text(title, fontSize = 20.sp, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary)
                }
                Text(body, color = Rackoon.colors.textSecondary, lineHeight = 21.sp)
            }
        }
        PrimaryButton("Try again", onRetry, Modifier.fillMaxWidth())
        Text("Rackoon keeps trying every few seconds while this screen is open.", color = Rackoon.colors.textMuted, fontSize = 12.sp)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Ready(state: ServerState, wide: Boolean, onRefresh: () -> Unit, onOpenTerminal: () -> Unit) {
    val o = state.overview ?: return
    var refreshing by remember { mutableStateOf(false) }
    LaunchedEffect(refreshing) { if (refreshing) { delay(900); refreshing = false } }
    PullToRefreshBox(isRefreshing = refreshing, onRefresh = { refreshing = true; onRefresh() }, modifier = Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            val ago = state.updatedAt?.let { Format.ago(it) }
            if (state.error != null) {
                Text("Showing the last reading${ago?.let { " ($it)" } ?: ""}. ${state.error}", color = Rackoon.colors.warn, fontSize = 12.sp)
            } else if (state.isStale) {
                Text("Last reading${ago?.let { " $it" } ?: ""}. Refreshing…", color = Rackoon.colors.textMuted, fontSize = 12.sp)
            }
            if (state.attention.isNotEmpty()) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    state.attention.forEach { AttentionChip(it, onClick = if (it.fix == "terminal") onOpenTerminal else null) }
                }
            }
            val usage: @Composable (Modifier) -> Unit = { m ->
                Column(m, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        val cpu = state.cpuPercent
                        StatCard(
                            "CPU", cpu?.let { "${it.toInt()}%" } ?: "—", "${o.cores} cores · load ${"%.2f".format(o.load1)}",
                            cpu?.div(100), Modifier.weight(1f),
                        )
                        StatCard("Memory", Format.bytes(o.memory.usedBytes), "of ${Format.bytes(o.memory.totalBytes)} · ${Format.percent(o.memory.usedFraction)}", o.memory.usedFraction, Modifier.weight(1f))
                    }
                    val root = o.disks.firstOrNull { it.mount == "/" } ?: o.disks.firstOrNull()
                    if (root != null) {
                        StatCard(
                            "Disk", Format.bytes(root.usedBytes), "of ${Format.bytes(root.totalBytes)} · ${root.usePercent}%  ${root.mount}",
                            root.usePercent / 100.0, Modifier.fillMaxWidth(), warn = root.usePercent > 85,
                        )
                    }
                }
            }
            if (wide) {
                // Tablet: usage on the left, the System card beside it.
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.Top) {
                    usage(Modifier.weight(1f))
                    Box(Modifier.weight(1f)) { SystemCard(o) }
                }
            } else {
                usage(Modifier.fillMaxWidth())
                SystemCard(o)
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable
private fun AttentionChip(item: AttentionItem, onClick: (() -> Unit)?) {
    val dot = if (item.severity == AttentionItem.Severity.CRITICAL) Rackoon.colors.danger else Rackoon.colors.warn
    Row(
        Modifier.height(40.dp).clip(RoundedCornerShape(10.dp)).background(Rackoon.colors.card)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        StatusDot(dot)
        Text(item.message.removeSuffix("."), color = Rackoon.colors.textPrimary, fontSize = 13.sp)
        if (onClick != null) androidx.compose.material3.Icon(com.bgallagher.rackoon.ui.theme.RackoonIcons.ChevronRight, null, tint = Rackoon.colors.textMuted, modifier = Modifier.size(14.dp))
    }
}

@Composable
private fun StatCard(label: String, value: String, sub: String, fraction: Double?, modifier: Modifier, warn: Boolean = false) {
    RCard(modifier) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            SectionLabel(label)
            Text(value, fontSize = 24.sp, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary)
            Text(sub, fontSize = 12.sp, color = Rackoon.colors.textSecondary)
            if (fraction != null) {
                Box(Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)).background(Rackoon.colors.border)) {
                    Box(
                        Modifier.fillMaxWidth(fraction.toFloat().coerceIn(0f, 1f)).height(4.dp).clip(RoundedCornerShape(2.dp))
                            .background(if (warn) Rackoon.colors.warn else Rackoon.colors.ok.copy(alpha = 0.8f)),
                    )
                }
            }
        }
    }
}

@Composable
private fun SystemCard(o: Overview) {
    val clipboard = LocalClipboard.current
    val scope = rememberCoroutineScope()
    fun copy(label: String, value: String) { scope.launch { clipboard.setClipEntry(androidx.compose.ui.platform.ClipEntry(ClipData.newPlainText(label, value))) } }
    RCard(Modifier.fillMaxWidth()) {
        Column {
            Row(Modifier.padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 6.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("System", fontSize = 16.sp, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary)
                Text(o.os.prettyName, fontSize = 13.sp, color = Rackoon.colors.textSecondary)
            }
            val rows = buildList {
                if (o.modelName.isNotEmpty()) add("Model" to o.modelName)
                add("Hostname" to o.hostname)
                add("Kernel" to o.kernel)
                add("Uptime" to Format.uptime(o.uptimeSeconds))
                o.ipAddress?.let { add("IP address" to it) }
                o.tailscaleIP?.let { add("Tailscale IP" to it) }
            }
            rows.forEach { (label, value) ->
                HorizontalDivider(color = Rackoon.colors.border)
                InfoRow(label, value, onCopy = if (label.endsWith("IP") || label == "IP address" || label == "Hostname") ({ copy(label, value) }) else null)
            }
        }
    }
}

/** Whether a VPN (Tailscale is one) is the phone's active network. Used only to word the "can't reach" hint. */
private fun vpnActive(context: android.content.Context): Boolean {
    val cm = context.getSystemService(android.net.ConnectivityManager::class.java) ?: return false
    val caps = cm.getNetworkCapabilities(cm.activeNetwork ?: return false) ?: return false
    return caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)
}
