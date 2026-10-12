package com.bgallagher.rackoon.ui

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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.bgallagher.rackoon.AppViewModel
import com.bgallagher.rackoon.DockerUi
import com.bgallagher.rackoon.core.ActionPrompts
import com.bgallagher.rackoon.core.ComposeAction
import com.bgallagher.rackoon.core.DockerAction
import com.bgallagher.rackoon.core.DockerContainer
import com.bgallagher.rackoon.core.DockerStack
import com.bgallagher.rackoon.core.Server
import com.bgallagher.rackoon.core.StackSeverity
import com.bgallagher.rackoon.core.status
import com.bgallagher.rackoon.core.usageText
import com.bgallagher.rackoon.output.ActionOutput
import com.bgallagher.rackoon.ui.theme.LocalTerminalTheme
import com.bgallagher.rackoon.ui.theme.Rackoon
import com.bgallagher.rackoon.ui.theme.RackoonIcons
import org.connectbot.terminal.Terminal

/** The stack page: header, stack actions, and the Containers and Output tabs (the design's StackDetail board). */
@Composable
fun StackDetail(vm: AppViewModel, server: Server, stack: DockerStack, ui: DockerUi.Ready, readOnly: Boolean, onBack: () -> Unit) {
    val c = Rackoon.colors
    val tab by vm.stackTab.collectAsStateWithLifecycle()
    val output by vm.output.collectAsStateWithLifecycle()
    val working by vm.working.collectAsStateWithLifecycle()
    val status = stack.status()
    val statusText = status.text.ifEmpty { if (stack.containers.size == 1) "Running" else "All ${stack.containers.size} running" }
    val blocked = vm.stackBlockedReason(stack)
    val ownOutput = output?.takeIf { it.scope == stack.name }
    var menu by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.padding(start = 0.dp, end = 4.dp).height(48.dp), verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f).height(48.dp).clip(RoundedCornerShape(24.dp)).clickable(onClick = onBack).padding(end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                IconTap(RackoonIcons.ChevronLeft, "Back to Docker", c.textPrimary, onBack)
                Text("Docker", color = c.textSecondary, fontSize = 15.sp)
            }
            Box {
                IconTap(RackoonIcons.More, "Stack actions", c.textPrimary, { menu = true })
                DropdownMenu(menu, { menu = false }, containerColor = c.selection) {
                    val entries = listOf(
                        ComposeAction.PULL to "Pull images", ComposeAction.UP to "Update", ComposeAction.RESTART to "Restart all",
                        ComposeAction.REBUILD to "Rebuild", ComposeAction.RECREATE to "Recreate…",
                    )
                    entries.forEach { (action, label) ->
                        DropdownMenuItem(
                            text = { Text(label, color = if (blocked != null) c.textMuted else if (action == ComposeAction.RECREATE) c.danger else c.textPrimary) },
                            enabled = blocked == null, onClick = { menu = false; vm.requestStackAction(stack, action) },
                        )
                    }
                    androidx.compose.material3.HorizontalDivider(color = c.border)
                    DropdownMenuItem(
                        text = { Text("Delete stack…", color = if (blocked != null) c.textMuted else c.danger, fontWeight = FontWeight.Medium) },
                        enabled = blocked == null, onClick = { menu = false; vm.requestDelete(stack) },
                    )
                }
            }
        }
        Row(Modifier.padding(horizontal = 16.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            LetterBadge(stack.name, 44.dp)
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stack.name, fontSize = 22.sp, fontWeight = FontWeight.Medium, color = c.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    StatusDot(severityColor(status.severity, dot = true))
                    Text(statusText, fontSize = 13.sp, color = if (status.severity == StackSeverity.OK) c.textSecondary else severityColor(status.severity))
                }
                stack.workingDir?.let { Text(it, fontFamily = MonoFamily, fontSize = 12.sp, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis) }
            }
        }
        Box(Modifier.padding(horizontal = 16.dp)) { LinkRow(stack, big = true) }
        if (readOnly) ReadOnlyBanner(onTurnOff = vm::toggleReadOnly)
        else if (blocked != null && working == null && tab == AppViewModel.StackTab.Containers) Text(blocked, color = c.textMuted, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp))
        // On the Output tab the panel itself says "Running…", and a row appearing here would push Cancel out from under the finger.
        working?.takeIf { tab != AppViewModel.StackTab.Output }?.let { w ->
            Row(Modifier.padding(horizontal = 20.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = c.accent)
                Text(w, color = c.textSecondary, fontSize = 13.sp)
            }
        }
        ui.actionError?.let { Text(it, color = c.danger, fontSize = 13.sp, lineHeight = 19.sp, modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp)) }
        if (ui.error != null) Text("Showing the last reading. ${ui.error}", color = c.warn, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 20.dp, vertical = 2.dp))

        TabStrip(
            listOf(
                AppViewModel.StackTab.Containers to "Containers", AppViewModel.StackTab.Logs to "Logs",
                AppViewModel.StackTab.Output to if (ownOutput?.isRunning == true) "Output ●" else "Output",
            ),
            tab, vm::showStackTab,
        )
        when (tab) {
            AppViewModel.StackTab.Containers -> LazyColumn(
                Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(stack.containers, key = { it.id }) { ct ->
                    ContainerCard(
                        ct, stack, busy = ct.id in ui.busy || stack.name in ui.busyStacks, readOnly = readOnly, anyRunning = working != null,
                        blocked = blocked, vm = vm,
                    )
                }
                val editable = com.bgallagher.rackoon.core.StackFiles.editable(stack)
                if (editable != null) item(key = "files") { FilesSection(editable) { vm.openEditor(stack, it) } }
            }
            AppViewModel.StackTab.Logs -> LogsPanel(vm, stack)
            AppViewModel.StackTab.Output -> if (ownOutput != null) ActionOutputPanel(ownOutput, onCancel = vm::cancelOutput, onClose = vm::closeOutput)
            else Text("Nothing has run for this stack yet. The output of Pull, Update, Restart and the container actions appears here.", color = c.textMuted, lineHeight = 20.sp, modifier = Modifier.padding(20.dp))
        }
    }
}

@Composable
private fun TabStrip(tabs: List<Pair<AppViewModel.StackTab, String>>, selected: AppViewModel.StackTab, onSelect: (AppViewModel.StackTab) -> Unit) {
    val c = Rackoon.colors
    Row(Modifier.fillMaxWidth().padding(top = 6.dp)) {
        tabs.forEach { (tab, label) ->
            val on = tab == selected
            Box(Modifier.weight(1f).height(48.dp).clickable { onSelect(tab) }, contentAlignment = Alignment.Center) {
                Text(label, fontWeight = FontWeight.Medium, color = if (on) c.textPrimary else c.textSecondary)
                Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(if (on) 3.dp else 1.dp).background(if (on) c.accent else c.border))
            }
        }
    }
}

@Composable
private fun ContainerCard(ct: DockerContainer, stack: DockerStack, busy: Boolean, readOnly: Boolean, anyRunning: Boolean, blocked: String?, vm: AppViewModel) {
    val c = Rackoon.colors
    val theme = LocalTerminalTheme.current
    var menu by remember { mutableStateOf(false) }
    val dot = when {
        ct.isUnhealthy -> c.danger
        ct.state == "restarting" || ct.state == "paused" -> c.warn
        ct.isRunning -> c.ok
        else -> c.idle
    }
    val canAct = !readOnly && !anyRunning
    val canRebuild = ActionPrompts.canRebuild(ct, stack)
    val shape = RoundedCornerShape(14.dp)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(c.card).border(1.dp, if (ct.isUnhealthy) c.danger.copy(alpha = 0.5f) else c.border, shape).padding(start = 14.dp, end = 4.dp, top = 12.dp),
    ) {
        Row(Modifier.padding(end = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (busy) CircularProgressIndicator(Modifier.size(10.dp), strokeWidth = 1.5.dp, color = c.accent) else StatusDot(dot)
            Text(ct.service ?: ct.name, fontSize = 16.sp, fontWeight = FontWeight.Medium, color = c.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            Text(ct.usageText(Format::bytes), fontFamily = MonoFamily, fontSize = 12.sp, color = if (ct.isUnhealthy) c.danger else c.textSecondary)
        }
        Text(ct.image, fontFamily = MonoFamily, fontSize = 12.sp, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(start = 16.dp))
        val ports = ct.ports.joinToString("  ") { "${it.hostPort}→${it.containerPort}" + if (it.proto != "tcp") "/${it.proto}" else "" }
        if (ports.isNotEmpty()) Text(ports, fontFamily = MonoFamily, fontSize = 12.sp, color = c.textMuted, modifier = Modifier.padding(start = 16.dp))
        Text(ct.status, fontSize = 12.sp, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(start = 16.dp, top = 2.dp))
        Row(Modifier.padding(start = 0.dp), verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f).alpha(if (canAct) 1f else 0.38f)) {
                if (ct.isRunning) {
                    ActionLink("Shell", canAct && !readOnly) { vm.openContainerShell(ct, theme) }
                    ActionLink("Restart", canAct) { vm.requestContainerAction(stack, ct, DockerAction.RESTART) }
                } else {
                    ActionLink("Start", canAct) { vm.requestContainerAction(stack, ct, DockerAction.START) }
                }
                if (canRebuild) ActionLink("Rebuild", canAct && blocked == null) { vm.requestRebuild(stack, ct) }
            }
            Box {
                IconTap(RackoonIcons.More, "More actions for ${ct.service ?: ct.name}", c.textSecondary, { menu = true })
                DropdownMenu(menu, { menu = false }, containerColor = c.selection) {
                    com.bgallagher.rackoon.core.StackFiles.editable(stack)?.firstOrNull { !it.isEnv }?.let { compose ->
                        DropdownMenuItem(text = { Text("View compose.yaml", color = c.textPrimary) }, onClick = { menu = false; vm.openEditor(stack, compose) })
                    }
                    DropdownMenuItem(
                        text = { Text("Stop…", color = if (canAct && ct.isRunning) c.danger else c.textMuted) },
                        enabled = canAct && ct.isRunning, onClick = { menu = false; vm.requestContainerAction(stack, ct, DockerAction.STOP) },
                    )
                }
            }
        }
        if (readOnly) Text("Disabled: Read-only mode is on", fontSize = 12.sp, color = c.textMuted, modifier = Modifier.padding(start = 16.dp, bottom = 10.dp))
        else Box(Modifier.height(2.dp))
    }
}

@Composable
private fun ActionLink(label: String, enabled: Boolean, onClick: () -> Unit) {
    TextButton(onClick, enabled = enabled, contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 12.dp)) {
        Text(label, color = if (enabled) Rackoon.colors.accent else Rackoon.colors.textMuted, fontWeight = FontWeight.Medium)
    }
}

/** The design's Files section: the stack's compose file(s) and `.env`, each opening the editor. */
@Composable
private fun FilesSection(files: List<com.bgallagher.rackoon.core.EditableFile>, onOpen: (com.bgallagher.rackoon.core.EditableFile) -> Unit) {
    val c = Rackoon.colors
    Column(Modifier.padding(top = 6.dp)) {
        SectionLabel("Files")
        RCard(Modifier.fillMaxWidth().padding(top = 8.dp)) {
            Column {
                files.forEachIndexed { i, f ->
                    if (i > 0) androidx.compose.material3.HorizontalDivider(color = c.border)
                    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable { onOpen(f) }.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(f.fileName, fontFamily = MonoFamily, color = c.textPrimary)
                            Text(f.path.substringBeforeLast('/'), fontSize = 12.sp, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        Icon(RackoonIcons.ChevronRight, null, tint = c.textMuted, modifier = Modifier.size(18.dp))
                    }
                }
            }
        }
        Text("Edits are syntax-checked on the server before anything is written.", fontSize = 12.sp, color = c.textMuted, lineHeight = 17.sp, modifier = Modifier.padding(top = 8.dp, start = 4.dp))
    }
}

/** The live output of a streamed action in a read-only terminal, with Cancel while it runs and Close afterwards. */
@Composable
fun ActionOutputPanel(output: ActionOutput, onCancel: () -> Unit, onClose: () -> Unit) {
    val c = Rackoon.colors
    val theme = LocalTerminalTheme.current
    val phase by output.phase.collectAsStateWithLifecycle()
    LaunchedEffect(theme) { output.applyTheme(theme) }
    val bg = androidx.compose.ui.graphics.Color(theme.backgroundRGB.r, theme.backgroundRGB.g, theme.backgroundRGB.b)
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            val (label, color) = when (val p = phase) {
                ActionOutput.Phase.Starting, ActionOutput.Phase.Running -> "Running…" to c.textSecondary
                ActionOutput.Phase.Succeeded -> "Finished" to c.ok
                is ActionOutput.Phase.Failed -> (p.exitCode?.let { "Failed (exit $it)" } ?: "Stopped before it finished") to c.danger
                ActionOutput.Phase.Cancelled -> "Cancelled" to c.warn
            }
            Column(Modifier.weight(1f)) {
                Text(output.title, fontFamily = MonoFamily, fontSize = 12.sp, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(label, color = color, fontWeight = FontWeight.Medium)
            }
            if (output.isRunning) SecondaryButton("Cancel", onCancel) else SecondaryButton("Close", onClose)
        }
        Box(Modifier.weight(1f).fillMaxWidth().background(bg)) {
            Terminal(
                output.emulator, Modifier.fillMaxSize(), keyboardEnabled = false, backgroundColor = bg,
                foregroundColor = androidx.compose.ui.graphics.Color(theme.foregroundRGB.r, theme.foregroundRGB.g, theme.foregroundRGB.b),
                initialFontSize = 9.sp,
            )
        }
    }
}
