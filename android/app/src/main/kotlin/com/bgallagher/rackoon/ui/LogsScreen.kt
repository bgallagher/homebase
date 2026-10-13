package com.bgallagher.rackoon.ui

import android.content.ClipData
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.ui.focus.focusRequester
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.bgallagher.rackoon.AppViewModel
import com.bgallagher.rackoon.core.DockerStack
import com.bgallagher.rackoon.core.LogEntry
import com.bgallagher.rackoon.core.LogLevel
import com.bgallagher.rackoon.core.LogView
import com.bgallagher.rackoon.core.logSource
import com.bgallagher.rackoon.ui.theme.Rackoon
import com.bgallagher.rackoon.ui.theme.RackoonIcons
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch

/** The stack's Logs tab (the design's Logs and LogsFiltered boards): every container merged, filterable, followable. */
@Composable
fun LogsPanel(vm: AppViewModel, stack: DockerStack, fullScreen: Boolean = false, onToggleFullScreen: () -> Unit = {}) {
    val c = Rackoon.colors
    val logs by vm.logs.collectAsStateWithLifecycle()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val ids = stack.containers.map { it.id }
    // Following runs only while this tab is on screen and the app is in the foreground; leaving it Ctrl-Cs every remote follower.
    LaunchedEffect(ids) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            vm.followLogs(stack.containers)
            try { awaitCancellation() } finally { vm.stopLogs() }
        }
    }

    val names = stack.containers.map { it.logSource }.distinct()
    var focus by rememberSaveable { mutableStateOf<String?>(null) }
    var level by rememberSaveable { mutableStateOf<LogLevel?>(null) }
    var search by rememberSaveable { mutableStateOf("") }
    val effectiveFocus = focus?.takeIf { it in names }
    val counts = remember(logs.entries, effectiveFocus) { LogView.counts(logs.entries, effectiveFocus) }
    val shown = remember(logs.entries, effectiveFocus, level, search) { LogView.filtered(logs.entries, effectiveFocus, level, search) }
    val showSource = names.size > 1 && effectiveFocus == null

    val listState = rememberLazyListState()
    var following by rememberSaveable { mutableStateOf(true) }
    var pausedAt by remember { mutableStateOf(0) }
    val atBottom by remember { derivedStateOf { val last = listState.layoutInfo.visibleItemsInfo.lastOrNull(); last == null || last.index >= listState.layoutInfo.totalItemsCount - 1 } }
    // Scrolling away pauses following; getting back to the end (or tapping Latest) resumes it.
    LaunchedEffect(listState.isScrollInProgress, atBottom) {
        if (listState.isScrollInProgress && !atBottom && following) { following = false; pausedAt = logs.received }
        else if (atBottom && !listState.isScrollInProgress && !following) following = true
    }
    LaunchedEffect(shown.size, following) { if (following && shown.isNotEmpty()) listState.scrollToItem(shown.lastIndex) }
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboard.current
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) { if (copied) { kotlinx.coroutines.delay(1500); copied = false } }
    val expanded = remember { mutableStateMapOf<Int, Boolean>() }

    var searching by rememberSaveable { mutableStateOf(false) }
    var compact by rememberSaveable { mutableStateOf(false) }
    var overflow by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        // Row 1: whether the log is following, then which container.
        Row(Modifier.fillMaxWidth().padding(start = 16.dp, top = 6.dp, bottom = 2.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            val (label, color) = when {
                !logs.live && logs.entries.isNotEmpty() -> "Ended" to c.textMuted
                following -> "Following" to c.okRole.mark
                else -> "Paused" to c.warnRole.mark
            }
            Row(
                Modifier.height(40.dp).clip(RoundedCornerShape(20.dp)).border(1.dp, c.border, RoundedCornerShape(20.dp))
                    .clickable { if (!following) { following = true; scope.launch { if (shown.isNotEmpty()) listState.scrollToItem(shown.lastIndex) } } else { following = false; pausedAt = logs.received } }
                    .padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Box(Modifier.size(8.dp).clip(CircleShape).background(color))
                Text(label, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = c.textPrimary)
            }
            Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()).padding(end = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (names.size > 1) Chip("All containers", effectiveFocus == null, c.textSecondary) { focus = null }
                names.forEachIndexed { i, n -> Chip(n, effectiveFocus == n || names.size == 1, c.series[i % c.series.size].label, dot = true) { focus = if (names.size == 1) null else n } }
            }
        }
        // Row 2: which level, with search and the rest behind icons. Search opens in place of the chips.
        if (searching) {
            Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Row(
                    Modifier.weight(1f).height(44.dp).clip(RoundedCornerShape(22.dp)).background(c.card).padding(horizontal = 14.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(RackoonIcons.Search, null, tint = c.textMuted, modifier = Modifier.size(16.dp))
                    val focusRequester = remember { androidx.compose.ui.focus.FocusRequester() }
                    LaunchedEffect(Unit) { focusRequester.requestFocus() }
                    Box(Modifier.weight(1f)) {
                        if (search.isEmpty()) Text("Search logs", color = c.textMuted, fontSize = 14.sp)
                        BasicTextField(
                            search, { search = it }, singleLine = true, modifier = Modifier.fillMaxWidth().focusRequester(focusRequester),
                            textStyle = androidx.compose.ui.text.TextStyle(color = c.textPrimary, fontSize = 14.sp), cursorBrush = SolidColor(c.textPrimary),
                            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
                        )
                    }
                    if (search.isNotEmpty()) Icon(RackoonIcons.Close, "Clear search", tint = c.textMuted, modifier = Modifier.size(16.dp).clickable { search = "" })
                }
                IconTap(RackoonIcons.Close, "Close search", c.textSecondary, { searching = false; search = "" })
            }
        } else {
            Row(Modifier.fillMaxWidth().padding(start = 16.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    LevelChip("All", counts[null] ?: 0, level == null) { level = null }
                    LevelChip("Error", counts[LogLevel.ERROR] ?: 0, level == LogLevel.ERROR) { level = LogLevel.ERROR }
                    LevelChip("Warn", counts[LogLevel.WARN] ?: 0, level == LogLevel.WARN) { level = LogLevel.WARN }
                    LevelChip("Info", counts[LogLevel.INFO] ?: 0, level == LogLevel.INFO) { level = LogLevel.INFO }
                    if ((counts[LogLevel.DEBUG] ?: 0) > 0 || level == LogLevel.DEBUG) LevelChip("Debug", counts[LogLevel.DEBUG] ?: 0, level == LogLevel.DEBUG) { level = LogLevel.DEBUG }
                }
                IconTap(RackoonIcons.Search, if (search.isNotEmpty()) "Search logs (filter on)" else "Search logs", if (search.isNotEmpty()) c.accent else c.textSecondary, { searching = true })
                Box {
                    IconTap(RackoonIcons.More, "Logs options", c.textSecondary, { overflow = true })
                    DropdownMenu(overflow, { overflow = false }, containerColor = c.selection) {
                        DropdownMenuItem(text = { Text(if (copied) "Copied" else "Copy visible logs", color = c.textPrimary) }, onClick = {
                            overflow = false
                            scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("Logs", LogView.text(shown, showSource)))); copied = true }
                        })
                        DropdownMenuItem(text = { Text(if (compact) "Two-line entries" else "Compact entries", color = c.textPrimary) }, onClick = { overflow = false; compact = !compact })
                        DropdownMenuItem(text = { Text(if (fullScreen) "Exit full screen" else "Full screen", color = c.textPrimary) }, onClick = { overflow = false; onToggleFullScreen() })
                    }
                }
            }
        }
        logs.error?.let { Text(it, color = c.danger, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp)) }

        Box(Modifier.weight(1f).fillMaxWidth()) {
            when {
                shown.isEmpty() -> Text(
                    if (logs.entries.isEmpty()) (if (logs.live) "Waiting for output…" else "No logs yet.") else "No lines match.",
                    color = c.textMuted, modifier = Modifier.padding(20.dp),
                )
                else -> LazyColumn(state = listState, modifier = Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 4.dp)) {
                    items(shown, key = { it.id }) { entry ->
                        LogRow(entry, c.series[names.indexOf(entry.source).coerceAtLeast(0) % c.series.size].label, showSource, compact, expanded[entry.id] == true) { expanded[entry.id] = expanded[entry.id] != true }
                        HorizontalDivider(color = c.border.copy(alpha = 0.5f))
                    }
                }
            }
            val fresh = logs.received - pausedAt
            if (!following && fresh > 0) {
                Row(
                    Modifier.align(Alignment.BottomCenter).padding(bottom = 16.dp).clip(RoundedCornerShape(22.dp)).background(c.accent)
                        .clickable { following = true; scope.launch { if (shown.isNotEmpty()) listState.scrollToItem(shown.lastIndex) } }.padding(horizontal = 16.dp, vertical = 11.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) { Text("Latest · $fresh new", color = c.accentText, fontWeight = FontWeight.SemiBold, fontSize = 14.sp) }
            }
        }
    }
}

@Composable
private fun Chip(label: String, on: Boolean, color: Color, dot: Boolean = false, onClick: () -> Unit) {
    val c = Rackoon.colors
    val shape = RoundedCornerShape(18.dp)
    Row(
        Modifier.height(36.dp).clip(shape).background(if (on) c.selection else Color.Transparent).border(1.dp, if (on) c.textMuted.copy(alpha = 0.5f) else c.border, shape)
            .clickable(onClick = onClick).padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (dot) Box(Modifier.size(8.dp).clip(CircleShape).background(color))
        Text(label, fontSize = 13.sp, color = if (on) c.textPrimary else c.textSecondary, maxLines = 1)
    }
}

@Composable
private fun LevelChip(label: String, count: Int, on: Boolean, onClick: () -> Unit) {
    val c = Rackoon.colors
    val shape = RoundedCornerShape(16.dp)
    Row(
        Modifier.height(32.dp).clip(shape).background(if (on) c.selection else Color.Transparent).border(1.dp, if (on) c.textMuted.copy(alpha = 0.5f) else c.border, shape)
            .clickable(onClick = onClick).padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(label, fontSize = 13.sp, color = if (on) c.textPrimary else c.textSecondary)
        Text("$count", fontSize = 12.sp, fontFamily = MonoFamily, color = c.textMuted)
    }
}

@Composable
private fun LogRow(entry: LogEntry, sourceColor: Color, showSource: Boolean, compact: Boolean, expanded: Boolean, onToggle: () -> Unit) {
    val c = Rackoon.colors
    val p = entry.parts
    val levelColor = when (p.level) { LogLevel.ERROR -> c.dangerRole.label; LogLevel.WARN -> c.warnRole.label; LogLevel.INFO -> c.info.label; LogLevel.DEBUG -> c.textDim; null -> c.textDim }
    val message: @Composable (Modifier) -> Unit = { m ->
        Text(
            p.message, fontFamily = MonoFamily, fontSize = 12.sp, lineHeight = 17.sp, color = if (p.level == LogLevel.DEBUG) c.textDim else c.textPrimary,
            maxLines = if (expanded) Int.MAX_VALUE else if (compact) 1 else 2, overflow = TextOverflow.Ellipsis, modifier = m,
        )
    }
    Row(Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(vertical = if (compact) 4.dp else 5.dp), verticalAlignment = Alignment.Top) {
        if (compact && !expanded) {
            Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                p.time?.let { Text(shortTime(it), fontFamily = MonoFamily, fontSize = 11.sp, lineHeight = 14.sp, color = c.textDim) }
                if (showSource) Text(entry.source, fontFamily = MonoFamily, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = sourceColor, maxLines = 1)
                p.level?.let { Text(it.name.take(4), fontFamily = MonoFamily, fontSize = 11.sp, fontWeight = FontWeight.Bold, color = levelColor) }
                message(Modifier.weight(1f))
            }
        } else Column(Modifier.weight(1f)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                p.time?.let { Text(shortTime(it), fontFamily = MonoFamily, fontSize = 11.sp, lineHeight = 14.sp, color = c.textDim) }
                if (showSource) Text(entry.source, fontFamily = MonoFamily, fontSize = 11.sp, lineHeight = 14.sp, fontWeight = FontWeight.SemiBold, color = sourceColor)
                p.level?.let { Text(it.name, fontFamily = MonoFamily, fontSize = 11.sp, lineHeight = 14.sp, fontWeight = FontWeight.Bold, color = levelColor) }
            }
            message(Modifier.padding(top = 1.dp))
        }
        // Long messages are cut; the arrow opens the whole thing.
        if (p.message.length > 70 || expanded) Icon(
            if (expanded) RackoonIcons.ChevronDown else RackoonIcons.ChevronRight, if (expanded) "Collapse entry" else "Expand entry",
            tint = c.textMuted, modifier = Modifier.padding(start = 6.dp, top = 2.dp).size(16.dp),
        )
    }
}

/** "2026-10-12T07:15:02.123Z" -> "07:15:02"; anything else is shown as it came. */
private fun shortTime(t: String): String = Regex("""T(\d{2}:\d{2}:\d{2})""").find(t)?.groupValues?.get(1) ?: t
