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
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.foundation.layout.Spacer
import com.bgallagher.rackoon.core.ImageName
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
import com.bgallagher.rackoon.core.StandaloneAction
import com.bgallagher.rackoon.core.status
import com.bgallagher.rackoon.core.usageText
import com.bgallagher.rackoon.output.ActionOutput
import com.bgallagher.rackoon.ui.theme.LocalTerminalTheme
import com.bgallagher.rackoon.ui.theme.Rackoon
import com.bgallagher.rackoon.ui.theme.RackoonIcons
import org.connectbot.terminal.Terminal

/**
 * The stack page: its own app bar (back, name and status, server, Read-only chip, menu), then tabs. On the Containers tab the header
 * (tile, path, link) scrolls away and the tabs pin under the bar; Logs and Output use the whole height, and Logs can go full screen.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun StackDetail(vm: AppViewModel, server: Server, stack: DockerStack, ui: DockerUi.Ready, readOnly: Boolean, onBack: () -> Unit) {
    val c = Rackoon.colors
    val tab by vm.stackTab.collectAsStateWithLifecycle()
    val output by vm.output.collectAsStateWithLifecycle()
    val working by vm.working.collectAsStateWithLifecycle()
    // A standalone container (docker run) has its own actions; compose ones are refused for it.
    val blocked = if (stack.isStandalone) vm.standaloneBlockedReason(stack) else vm.stackBlockedReason(stack)
    val ownOutput = output?.takeIf { it.scope == stack.id }
    var logsFull by rememberSaveable { mutableStateOf(false) }
    val fullScreen = logsFull && tab == AppViewModel.StackTab.Logs
    androidx.activity.compose.BackHandler(enabled = fullScreen) { logsFull = false }
    val tabs = listOf(
        AppViewModel.StackTab.Containers to "Containers", AppViewModel.StackTab.Logs to "Logs",
        AppViewModel.StackTab.Output to if (ownOutput?.isRunning == true) "Output ●" else "Output",
    )

    Column(Modifier.fillMaxSize()) {
        if (!fullScreen) {
            StackAppBar(vm, server, stack, readOnly, blocked, onBack)
            // What is happening right now stays in view on every tab.
            working?.takeIf { tab != AppViewModel.StackTab.Output }?.let { w ->
                Row(Modifier.padding(horizontal = 20.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = c.accent)
                    Text(w, color = c.textSecondary, fontSize = 13.sp)
                }
            }
            ui.actionError?.let { Text(it, color = c.dangerRole.label, fontSize = 13.sp, lineHeight = 19.sp, modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp)) }
            if (ui.error != null) Text("Showing the last reading. ${ui.error}", color = c.warnRole.label, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 20.dp, vertical = 2.dp))
        }
        when {
            fullScreen -> LogsPanel(vm, stack, fullScreen = true, onToggleFullScreen = { logsFull = false })
            tab == AppViewModel.StackTab.Containers -> LazyColumn(
                Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                item(key = "header") { StackHeader(vm, stack) }
                if (readOnly) item(key = "readonly") { ReadOnlyBanner(onTurnOff = vm::toggleReadOnly) }
                else if (blocked != null && working == null) item(key = "blocked") { Text(blocked, color = c.textMuted, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 20.dp)) }
                stickyHeader(key = "tabs") { Box(Modifier.background(c.background)) { TabStrip(tabs, tab, vm::showStackTab) } }
                items(stack.containers, key = { it.id }) { ct ->
                    Box(Modifier.padding(horizontal = 16.dp)) {
                        ContainerCard(
                            ct, stack, busy = ct.id in ui.busy || stack.id in ui.busyStacks, readOnly = readOnly, anyRunning = working != null,
                            blocked = blocked, vm = vm,
                        )
                    }
                }
                val editable = com.bgallagher.rackoon.core.StackFiles.editable(stack)
                if (editable != null) item(key = "files") { Box(Modifier.padding(horizontal = 16.dp)) { FilesSection(editable) { vm.openEditor(stack, it) } } }
            }
            else -> Column(Modifier.fillMaxSize()) {
                TabStrip(tabs, tab, vm::showStackTab)
                when (tab) {
                    AppViewModel.StackTab.Logs -> LogsPanel(vm, stack, fullScreen = false, onToggleFullScreen = { logsFull = true })
                    else -> if (ownOutput != null) ActionOutputPanel(ownOutput, onCancel = vm::cancelOutput, onClose = vm::closeOutput)
                    else Text("Nothing has run for this stack yet. The output of Pull, Update, Restart and the container actions appears here.", color = c.textMuted, lineHeight = 20.sp, modifier = Modifier.padding(20.dp))
                }
            }
        }
    }
}

/** Back, the stack's name with its status dot, the server it is on (tap to switch), the Read-only chip and the stack menu. */
@Composable
private fun StackAppBar(vm: AppViewModel, server: Server, stack: DockerStack, readOnly: Boolean, blocked: String?, onBack: () -> Unit) {
    val c = Rackoon.colors
    val status = stack.status()
    val statusText = status.text.ifEmpty { if (stack.containers.size == 1) "Running" else "All ${stack.containers.size} running" }
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().height(64.dp).padding(start = 4.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        IconTap(RackoonIcons.ChevronLeft, "Back to Docker", c.textPrimary, onBack)
        Column(Modifier.weight(1f).clip(RoundedCornerShape(10.dp)).clickable { vm.showSwitcher(true) }.padding(horizontal = 6.dp, vertical = 4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stack.name, fontSize = 20.sp, fontWeight = FontWeight.Medium, color = c.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                StatusDot(severityColor(status.severity, dot = true))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(statusText, fontSize = 12.sp, color = if (status.severity == StackSeverity.OK) c.textSecondary else severityLabel(status.severity), maxLines = 1)
                Text("· ${server.name}", fontSize = 12.sp, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
            }
        }
        ReadOnlyChip(readOnly, vm::toggleReadOnly, small = true)
        Box {
            IconTap(RackoonIcons.More, "Stack actions", c.textPrimary, { menu = true })
            if (stack.isStandalone) StandaloneMenu(menu, { menu = false }, vm, stack, blocked)
            else StackMenu(menu, { menu = false }, vm, stack, blocked)
        }
    }
}

@Composable
internal fun severityLabel(s: StackSeverity): androidx.compose.ui.graphics.Color = when (s) {
    StackSeverity.OK -> Rackoon.colors.okRole.label
    StackSeverity.WARNING -> Rackoon.colors.warnRole.label
    StackSeverity.DANGER -> Rackoon.colors.dangerRole.label
    StackSeverity.IDLE -> Rackoon.colors.textMuted
}

/** The stack's actions. Same commands as the Mac's menu; each opens the confirm sheet with the exact command. Only Delete is red. */
@Composable
private fun StackMenu(open: Boolean, onDismiss: () -> Unit, vm: AppViewModel, stack: DockerStack, blocked: String?) {
    val c = Rackoon.colors
    val entries = listOf(
        Triple(ComposeAction.PULL, "Pull images", "Download newer images only"),
        Triple(ComposeAction.UP, "Update", "Recreate what changed"),
        Triple(ComposeAction.RESTART, "Restart all", "Stop and start, same images"),
        Triple(ComposeAction.REBUILD, "Rebuild", "Rebuild images, then recreate"),
        Triple(ComposeAction.RECREATE, "Recreate…", "Fresh containers; volumes stay"),
    )
    DropdownMenu(open, onDismiss, modifier = Modifier.width(280.dp), offset = androidx.compose.ui.unit.DpOffset((-8).dp, 0.dp), containerColor = c.selection) {
        entries.forEach { (action, label, subtitle) ->
            DropdownMenuItem(
                text = { MenuText(label, subtitle, if (blocked != null) c.textMuted else c.textPrimary) },
                modifier = Modifier.heightIn(min = 56.dp), enabled = blocked == null, onClick = { onDismiss(); vm.requestStackAction(stack, action) },
            )
        }
        if (stack.hasBookmark) DropdownMenuItem(
            text = { MenuText("Edit bookmark", "Change the link on Bookmarks", c.textPrimary) },
            modifier = Modifier.heightIn(min = 56.dp), onClick = { onDismiss(); vm.openBookmarkSheet(stack.id) },
        )
        androidx.compose.material3.HorizontalDivider(color = c.border)
        DropdownMenuItem(
            text = { MenuText("Delete stack…", "Containers and networks; volumes optional", if (blocked != null) c.textMuted else c.danger) },
            modifier = Modifier.heightIn(min = 56.dp), enabled = blocked == null, onClick = { onDismiss(); vm.requestDelete(stack) },
        )
    }
}

/**
 * The same menu for a container started with `docker run`: Pull Latest Image, Restart (or Start) Container and Delete Container.
 * Update, Rebuild and Recreate need the definition a compose file holds, which such a container doesn't have, so they stay
 * visible but disabled and say why.
 */
@Composable
private fun StandaloneMenu(open: Boolean, onDismiss: () -> Unit, vm: AppViewModel, stack: DockerStack, blocked: String?) {
    val c = Rackoon.colors
    val image = StandaloneAction.pullableImage(stack)
    val container = stack.containers.firstOrNull()
    val ok = blocked == null
    DropdownMenu(open, onDismiss, modifier = Modifier.width(280.dp), offset = androidx.compose.ui.unit.DpOffset((-8).dp, 0.dp), containerColor = c.selection) {
        DropdownMenuItem(
            text = { MenuText("Update", StandaloneAction.NEEDS_COMPOSE_REASON, c.textMuted) },
            modifier = Modifier.heightIn(min = 56.dp), enabled = false, onClick = {},
        )
        DropdownMenuItem(
            text = {
                MenuText(
                    "Pull latest image",
                    if (image == null) "The container runs an untagged image, so there is nothing to pull" else "Download a newer $image; the container keeps the image it has",
                    if (ok && image != null) c.textPrimary else c.textMuted,
                )
            },
            modifier = Modifier.heightIn(min = 56.dp), enabled = ok && image != null, onClick = { onDismiss(); vm.requestPull(stack) },
        )
        DropdownMenuItem(
            text = { MenuText("Rebuild", StandaloneAction.NEEDS_COMPOSE_REASON, c.textMuted) },
            modifier = Modifier.heightIn(min = 56.dp), enabled = false, onClick = {},
        )
        if (container != null) {
            val restart = container.isRunning
            DropdownMenuItem(
                text = {
                    MenuText(
                        if (restart) "Restart container" else "Start container",
                        if (restart) "Restart in place; its settings are not changed" else "Start it again with the settings it was created with",
                        if (ok) c.textPrimary else c.textMuted,
                    )
                },
                modifier = Modifier.heightIn(min = 56.dp), enabled = ok,
                onClick = { onDismiss(); vm.requestContainerAction(stack, container, if (restart) DockerAction.RESTART else DockerAction.START) },
            )
        }
        androidx.compose.material3.HorizontalDivider(color = c.border)
        DropdownMenuItem(
            text = { MenuText("Recreate…", StandaloneAction.NEEDS_COMPOSE_REASON, c.textMuted) },
            modifier = Modifier.heightIn(min = 56.dp), enabled = false, onClick = {},
        )
        DropdownMenuItem(
            text = { MenuText("Delete container…", "Stop and remove it; anonymous volumes optional", if (ok) c.danger else c.textMuted) },
            modifier = Modifier.heightIn(min = 56.dp), enabled = ok, onClick = { onDismiss(); vm.requestDelete(stack) },
        )
    }
}

@Composable
private fun MenuText(title: String, subtitle: String, color: androidx.compose.ui.graphics.Color) {
    Column {
        Text(title, color = color, fontWeight = FontWeight.Medium)
        Text(subtitle, color = Rackoon.colors.textMuted, fontSize = 12.sp, lineHeight = 16.sp)
    }
}

/** The part of the page that scrolls away: the stack's tile, where it lives, and its link. */
@Composable
private fun StackHeader(vm: AppViewModel, stack: DockerStack) {
    val c = Rackoon.colors
    Column(Modifier.padding(horizontal = 16.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            SiteIcon(stack.name, stack.containers.firstNotNullOfOrNull { it.bookmark?.href }, 40.dp, vm.favicons)
            stack.workingDir?.let { Text(it, fontFamily = MonoFamily, fontSize = 12.sp, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f)) }
        }
        LinkRow(stack, big = true)
    }
}

@Composable
private fun TabStrip(tabs: List<Pair<AppViewModel.StackTab, String>>, selected: AppViewModel.StackTab, onSelect: (AppViewModel.StackTab) -> Unit) {
    val c = Rackoon.colors
    Row(Modifier.fillMaxWidth()) {
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
    // A dot only says something when it is not the usual state: healthy running containers have none (the stack's dot covers them).
    val dot = when {
        ct.isUnhealthy -> c.danger
        ct.state == "restarting" || ct.state == "paused" -> c.warn
        ct.isRunning -> null
        else -> c.idle
    }
    val canAct = !readOnly && !anyRunning
    val canRebuild = ActionPrompts.canRebuild(ct, stack)
    val shape = RoundedCornerShape(14.dp)
    val image = ImageName.parse(ct.image)
    val portsText = ct.ports.take(2).joinToString(", ") { "${it.hostPort}→${it.containerPort}" + if (it.proto != "tcp") "/${it.proto}" else "" } +
        if (ct.ports.size > 2) " +${ct.ports.size - 2}" else ""
    Column(
        Modifier.fillMaxWidth().clip(shape).background(c.card).border(1.dp, if (ct.isUnhealthy) c.danger.copy(alpha = 0.6f) else c.border, shape).padding(start = 14.dp, end = 4.dp, top = 12.dp),
    ) {
        Row(Modifier.padding(end = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (busy) CircularProgressIndicator(Modifier.size(10.dp), strokeWidth = 1.5.dp, color = c.accent) else dot?.let { StatusDot(it) }
            Text(ct.service ?: ct.name, fontSize = 16.sp, fontWeight = FontWeight.Medium, color = if (ct.isUnhealthy) c.dangerRole.label else c.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            if (ct.isUnhealthy) Text("unhealthy", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = c.dangerRole.label)
            else Text(ct.usageText(Format::bytes), fontFamily = MonoFamily, fontSize = 12.sp, color = c.textSecondary)
        }
        // The tag is the useful part of an image name, so only the repository is ever shortened.
        Row(Modifier.padding(top = 2.dp, end = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(image.repository, fontFamily = MonoFamily, fontSize = 12.sp, color = c.textMuted, maxLines = 1, overflow = TextOverflow.MiddleEllipsis, modifier = Modifier.weight(1f, fill = false))
            image.tag?.let { Text(it, fontFamily = MonoFamily, fontSize = 12.sp, color = c.textPrimary, maxLines = 1, softWrap = false) }
        }
        Text(
            ct.status + if (portsText.isNotEmpty()) " · $portsText" else "", fontSize = 12.sp, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 2.dp),
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f).alpha(if (canAct) 1f else 0.38f), verticalAlignment = Alignment.CenterVertically) {
                if (ct.isRunning) {
                    ActionLink("Shell", canAct && !readOnly) { vm.openContainerShell(ct, theme) }
                    ActionLink("Restart", canAct) { vm.requestContainerAction(stack, ct, DockerAction.RESTART) }
                } else {
                    ActionLink("Start", canAct) { vm.requestContainerAction(stack, ct, DockerAction.START) }
                }
                // Rebuild is the heavier action: a little room keeps it from being tapped by accident next to Restart.
                if (canRebuild) { Spacer(Modifier.width(8.dp)); ActionLink("Rebuild", canAct && blocked == null) { vm.requestRebuild(stack, ct) } }
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
        if (readOnly) Text("Disabled: Read-only mode is on", fontSize = 12.sp, color = c.textMuted, modifier = Modifier.padding(bottom = 10.dp))
        else Box(Modifier.height(2.dp))
    }
}

/** Container actions are plain text buttons: accent is kept for the one primary action on a screen. */
@Composable
private fun ActionLink(label: String, enabled: Boolean, onClick: () -> Unit) {
    TextButton(onClick, enabled = enabled, contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 12.dp)) {
        Text(label, color = if (enabled) Rackoon.colors.textPrimary else Rackoon.colors.textMuted, fontWeight = FontWeight.Medium, fontSize = 14.sp)
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
