package com.bgallagher.rackoon.ui

import android.content.ClipData
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.bgallagher.rackoon.AppViewModel
import com.bgallagher.rackoon.BookmarkForm
import com.bgallagher.rackoon.DockerUi
import com.bgallagher.rackoon.core.BookmarkItem
import com.bgallagher.rackoon.core.LinkScope
import com.bgallagher.rackoon.core.StackFiles
import com.bgallagher.rackoon.core.bookmarkGroups
import com.bgallagher.rackoon.core.bookmarkItems
import com.bgallagher.rackoon.core.bookmarkableStacks
import com.bgallagher.rackoon.core.serviceNames
import com.bgallagher.rackoon.core.shortAddress
import com.bgallagher.rackoon.ui.theme.Rackoon
import com.bgallagher.rackoon.ui.theme.RackoonIcons
import kotlinx.coroutines.launch

private fun scopeColor(scope: LinkScope) = when (scope) {
    LinkScope.LOCAL -> Color(0xFF8DB4F0)
    LinkScope.TAILSCALE -> Color(0xFF6FD3A8)
    LinkScope.PUBLIC -> Color(0xFFF0A27A)
}

private fun scopeHint(scope: LinkScope) = when (scope) {
    LinkScope.LOCAL -> "Reachable on your home network only"
    LinkScope.TAILSCALE -> "Needs Tailscale connected on this phone"
    LinkScope.PUBLIC -> "Open to anyone with the link"
}

/** More > Bookmarks: every service with Homepage labels, grouped by where its link works. Add, edit and remove write the labels. */
@Composable
fun BookmarksScreen(vm: AppViewModel, readOnly: Boolean, onBack: () -> Unit) {
    BackHandler(onBack = onBack)
    val c = Rackoon.colors
    val docker by vm.docker.collectAsStateWithLifecycle()
    val message by vm.bookmarkMessage.collectAsStateWithLifecycle()
    val busy by vm.bookmarkBusy.collectAsStateWithLifecycle()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    // The list comes from the Docker poll, so keep it running while this screen is open.
    LaunchedEffect(Unit) { lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { vm.pollDockerWhileVisible() } }
    var query by remember { mutableStateOf("") }
    val ready = docker as? DockerUi.Ready
    val canAdd = ready?.snapshot?.bookmarkableStacks?.isNotEmpty() == true

    Column(Modifier.fillMaxSize().background(c.background).statusBarsPadding()) {
        Row(Modifier.height(64.dp).padding(start = 4.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconTap(RackoonIcons.ChevronLeft, "Back to More", c.textPrimary, onBack)
            Text("Bookmarks", fontSize = 18.sp, fontWeight = FontWeight.Medium, color = c.textPrimary, modifier = Modifier.weight(1f))
            // Always tappable: when it can't open the sheet, the reason shows below instead of nothing happening.
            IconTap(RackoonIcons.Plus, "Add bookmark", if (canAdd && !readOnly) c.textPrimary else c.textMuted, { vm.openBookmarkSheet() })
        }
        if (readOnly) ReadOnlyBanner(onTurnOff = vm::toggleReadOnly)
        busy?.let { Row(Modifier.padding(horizontal = 20.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = c.accent)
            Text(it, color = c.textSecondary, fontSize = 13.sp)
        } }
        message?.let { Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(it, color = c.danger, fontSize = 13.sp, lineHeight = 19.sp, modifier = Modifier.weight(1f))
            TextButton(vm::dismissBookmarkMessage) { Text("Dismiss", color = c.textSecondary) }
        } }
        when {
            ready == null -> Box(Modifier.fillMaxSize().padding(24.dp)) {
                Text(
                    if (docker is DockerUi.Failed) (docker as DockerUi.Failed).message else if (docker == DockerUi.NotInstalled) "Docker isn't installed on this server." else "Reading containers…",
                    color = c.textSecondary, lineHeight = 21.sp,
                )
            }
            else -> {
                val items = ready.snapshot.bookmarkItems
                if (items.isEmpty()) {
                    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        RCard(Modifier.fillMaxWidth()) {
                            Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text("No bookmarks yet", fontSize = 18.sp, fontWeight = FontWeight.Medium, color = c.textPrimary)
                                Text(
                                    "A bookmark is a link to a service, stored as Homepage labels (homepage.href, homepage.name, …) in its compose file, so other tools that read them see it too.",
                                    color = c.textSecondary, lineHeight = 21.sp,
                                )
                            }
                        }
                        if (canAdd) PrimaryButton("Add bookmark", { vm.openBookmarkSheet() }, Modifier.fillMaxWidth(), enabled = !readOnly)
                    }
                } else {
                    SearchField(query) { query = it }
                    val shown = items.filter { matches(it, query) }
                    LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 4.dp)) {
                        for (scope in LinkScope.entries) {
                            val rows = shown.filter { LinkScope.of(it.bookmark.href) == scope }.sortedBy { it.title.lowercase() }
                            if (rows.isEmpty()) continue
                            item(key = "h-$scope") { ScopeHeader(scope) }
                            items(rows, key = { it.id }) { item ->
                                BookmarkRow(item, readOnly, onEdit = { vm.openBookmarkSheet(item.stack.name, item.service) },
                                    onRemove = { vm.requestBookmarkRemovalFor(item.stack.name, item.service) })
                            }
                        }
                        if (shown.isEmpty()) item { Text("No bookmarks match “$query”.", color = c.textMuted, modifier = Modifier.padding(16.dp)) }
                        item { Box(Modifier.navigationBarsPadding().height(16.dp)) }
                    }
                }
            }
        }
    }
}

private fun matches(item: BookmarkItem, query: String): Boolean {
    val q = query.trim().lowercase()
    if (q.isEmpty()) return true
    return listOf(item.title, item.bookmark.href, item.bookmark.group.orEmpty(), item.stack.name, item.service).any { it.lowercase().contains(q) }
}

@Composable
fun ReadOnlyBanner(onTurnOff: () -> Unit) {
    val c = Rackoon.colors
    val shape = RoundedCornerShape(14.dp)
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp).clip(shape).background(c.card).border(1.dp, c.border, shape).padding(start = 16.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(RackoonIcons.Lock, null, tint = c.accent, modifier = Modifier.size(20.dp))
        Text("Read-only mode is on. Actions that change the server are disabled.", color = c.textPrimary, lineHeight = 20.sp, modifier = Modifier.weight(1f).padding(vertical = 8.dp))
        TextButton(onTurnOff) { Text("Turn off", color = c.accent, fontWeight = FontWeight.SemiBold) }
    }
}

@Composable
private fun SearchField(value: String, onChange: (String) -> Unit) {
    val c = Rackoon.colors
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp).height(48.dp).clip(RoundedCornerShape(24.dp)).background(c.card).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(RackoonIcons.Search, null, tint = c.textMuted, modifier = Modifier.size(18.dp))
        Box(Modifier.weight(1f)) {
            if (value.isEmpty()) Text("Search bookmarks", color = c.textMuted)
            BasicTextField(
                value, onChange, singleLine = true, modifier = Modifier.fillMaxWidth(),
                textStyle = androidx.compose.ui.text.TextStyle(color = c.textPrimary, fontSize = 15.sp), cursorBrush = SolidColor(c.textPrimary),
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
            )
        }
    }
}

@Composable
private fun ScopeHeader(scope: LinkScope) {
    val c = Rackoon.colors
    Column(Modifier.padding(start = 4.dp, end = 4.dp, top = 16.dp, bottom = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            StatusDot(scopeColor(scope))
            Text(scope.title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = c.textPrimary)
        }
        Text(scopeHint(scope), fontSize = 12.sp, color = c.textMuted, modifier = Modifier.padding(start = 16.dp, top = 2.dp))
    }
}

@Composable
private fun BookmarkRow(item: BookmarkItem, readOnly: Boolean, onEdit: () -> Unit, onRemove: () -> Unit) {
    val c = Rackoon.colors
    val uri = LocalUriHandler.current
    val clipboard = LocalClipboard.current
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(14.dp)
    Row(
        Modifier.fillMaxWidth().padding(bottom = 8.dp).heightIn(min = 68.dp).clip(shape).background(c.card).border(1.dp, c.border, shape).padding(start = 14.dp, top = 8.dp, bottom = 8.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        LetterBadge(item.title, 36.dp)
        Column(Modifier.weight(1f)) {
            Text(item.title, fontWeight = FontWeight.Medium, color = c.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(item.bookmark.shortAddress(), fontFamily = MonoFamily, fontSize = 12.sp, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 2.dp))
        }
        TextButton({ runCatching { uri.openUri(item.bookmark.href) } }) { Text("Open", color = c.accent, fontWeight = FontWeight.SemiBold) }
        Box {
            IconTap(RackoonIcons.More, "More actions for ${item.title}", c.textSecondary, { menu = true })
            DropdownMenu(menu, { menu = false }, containerColor = c.selection) {
                DropdownMenuItem(
                    text = { Text("Copy address", color = c.textPrimary) },
                    onClick = { menu = false; scope.launch { clipboard.setClipEntry(androidx.compose.ui.platform.ClipEntry(ClipData.newPlainText("Bookmark", item.bookmark.href))) } },
                )
                DropdownMenuItem(
                    text = { Text(if (readOnly) "Edit (Read-only is on)" else "Edit", color = if (readOnly) c.textMuted else c.textPrimary) },
                    enabled = !readOnly, onClick = { menu = false; onEdit() },
                )
                DropdownMenuItem(
                    text = { Text(if (readOnly) "Remove (Read-only is on)" else "Remove", color = if (readOnly) c.textMuted else c.danger) },
                    enabled = !readOnly, onClick = { menu = false; onRemove() },
                )
            }
        }
    }
}

// MARK: add / edit sheet

/** The modal for adding, editing or removing a service's bookmark. Nothing is written until the diff is confirmed. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun BookmarkSheet(vm: AppViewModel, form: BookmarkForm, readOnly: Boolean) {
    val c = Rackoon.colors
    val docker by vm.docker.collectAsStateWithLifecycle()
    val snapshot = (docker as? DockerUi.Ready)?.snapshot
    val stack = snapshot?.stacks?.firstOrNull { it.name == form.stackName }
    val choices = snapshot?.bookmarkableStacks.orEmpty()
    val groups = snapshot?.bookmarkGroups.orEmpty()
    val blocked = form.saveBlockedReason(readOnly, stack)
    val busy = form.busy != null

    ModalBottomSheet(
        onDismissRequest = { if (!busy) vm.closeBookmarkSheet() }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = c.sidebar, scrimColor = Color.Black.copy(alpha = 0.6f),
    ) {
        Column(Modifier.imePadding().padding(horizontal = 20.dp).verticalScroll(rememberScrollState()).padding(bottom = 16.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(if (form.existing == null) RackoonIcons.Bookmark else RackoonIcons.BookmarkFilled, null, tint = c.accent, modifier = Modifier.size(22.dp))
                Text(if (form.existing == null) "Add bookmark" else "Edit bookmark", fontSize = 20.sp, fontWeight = FontWeight.Medium, color = c.textPrimary)
            }
            if (readOnly) ReadOnlyBannerInline(vm::toggleReadOnly)

            if (!form.stackLocked) Picker("Stack", form.stackName ?: "Choose a stack", choices.map { it.name }, !busy) { vm.chooseBookmarkStack(it) }
            val services = stack?.serviceNames.orEmpty()
            if (services.size > 1) Picker("Container", form.service, services, !busy) { vm.chooseBookmarkService(it) }
            else if (stack != null && form.service.isNotEmpty() && !form.stackLocked) Text("Container: ${form.service}", fontSize = 12.sp, color = c.textMuted)

            Field("Web address", form.url, "https://app.example.com", mono = true, enabled = !busy, keyboard = androidx.compose.ui.text.input.KeyboardType.Uri) { v -> vm.editBookmark { it.copy(url = v) } }
            form.urlProblem?.let { Text(it, color = c.danger, fontSize = 12.sp) }
            Field("Name", form.name, form.service.ifEmpty { "Name" }, enabled = !busy) { v -> vm.editBookmark { it.copy(name = v) } }
            Column {
                Field("Group", form.group, "Media", enabled = !busy) { v -> vm.editBookmark { it.copy(group = v) } }
                if (groups.isNotEmpty()) {
                    FlowRow(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        groups.forEach { g ->
                            Text(
                                g, fontSize = 13.sp, color = c.textPrimary,
                                modifier = Modifier.clip(RoundedCornerShape(16.dp)).background(c.card).clickable(enabled = !busy) { vm.editBookmark { it.copy(group = g) } }.padding(horizontal = 12.dp, vertical = 7.dp),
                            )
                        }
                    }
                }
            }
            Field("Icon (optional)", form.icon, "name.png, or a dashboard-icons name", enabled = !busy) { v -> vm.editBookmark { it.copy(icon = v) } }
            Field("Description (optional)", form.details, "What it is", enabled = !busy) { v -> vm.editBookmark { it.copy(details = v) } }
            Text("Saved as Homepage labels (homepage.href, homepage.name, …) in the stack's compose file, so other tools that read them see it too.", fontSize = 12.sp, color = c.textMuted, lineHeight = 17.sp)

            if (form.busy != null) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = c.accent)
                    Text(form.busy, color = c.textSecondary, fontSize = 13.sp)
                }
            }
            form.notice?.let { Text(it, color = c.danger, fontSize = 13.sp, lineHeight = 19.sp) }
            if (blocked != null && stack != null && form.url.isNotBlank() && !readOnly) Text(blocked, fontSize = 12.sp, color = c.textMuted)

            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                SecondaryButton("Save only", { vm.requestBookmarkSave(apply = false) }, Modifier.weight(1f), enabled = blocked == null)
                PrimaryButton("Save and apply", { vm.requestBookmarkSave(apply = true) }, Modifier.weight(1f), enabled = blocked == null)
            }
            Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                if (form.existing != null) TextButton({ vm.requestBookmarkRemoval() }, enabled = !busy && !readOnly) { Text("Remove bookmark", color = if (!busy && !readOnly) c.danger else c.textMuted) }
                else Box(Modifier)
                TextButton({ vm.closeBookmarkSheet() }, enabled = !busy) { Text("Cancel", color = c.textSecondary) }
            }
            Text("Save and apply updates the stack so the label shows up, which recreates the container (a few seconds of downtime).", fontSize = 12.sp, color = c.textMuted, lineHeight = 17.sp)
        }
    }
}

@Composable
private fun ReadOnlyBannerInline(onTurnOff: () -> Unit) {
    val c = Rackoon.colors
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(RackoonIcons.Lock, null, tint = c.accent, modifier = Modifier.size(16.dp))
        Text("Read-only mode is on, so nothing can be saved.", fontSize = 13.sp, color = c.textSecondary, modifier = Modifier.weight(1f))
        TextButton(onTurnOff) { Text("Turn off", color = c.accent, fontWeight = FontWeight.SemiBold) }
    }
}

/** A labelled dropdown: tap to choose one of [options]. */
@Composable
internal fun Picker(label: String, value: String, options: List<String>, enabled: Boolean, onPick: (String) -> Unit) {
    val c = Rackoon.colors
    var open by remember { mutableStateOf(false) }
    Column {
        Text(label, color = c.textSecondary, fontSize = 13.sp, modifier = Modifier.padding(start = 2.dp, bottom = 6.dp))
        Box {
            Row(
                Modifier.fillMaxWidth().height(56.dp).clip(RoundedCornerShape(12.dp)).background(c.card).border(1.dp, c.border, RoundedCornerShape(12.dp))
                    .clickable(enabled = enabled) { open = true }.padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(value, color = c.textPrimary, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Icon(RackoonIcons.ChevronDown, null, tint = c.textSecondary, modifier = Modifier.size(18.dp))
            }
            DropdownMenu(open, { open = false }, containerColor = c.selection) {
                options.forEach { o -> DropdownMenuItem(text = { Text(o, color = c.textPrimary) }, onClick = { open = false; onPick(o) }) }
            }
        }
    }
}
