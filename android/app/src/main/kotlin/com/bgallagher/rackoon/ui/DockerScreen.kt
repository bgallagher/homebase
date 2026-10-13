package com.bgallagher.rackoon.ui

import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.bgallagher.rackoon.AppViewModel
import com.bgallagher.rackoon.DockerUi
import com.bgallagher.rackoon.core.DockerContainer
import com.bgallagher.rackoon.core.DockerSnapshot
import com.bgallagher.rackoon.core.DockerStack
import com.bgallagher.rackoon.core.LetterTile
import com.bgallagher.rackoon.core.LinkScope
import com.bgallagher.rackoon.core.Server
import com.bgallagher.rackoon.core.bookmarkableStacks
import com.bgallagher.rackoon.core.StackSeverity
import com.bgallagher.rackoon.core.bookmarkLinks
import com.bgallagher.rackoon.core.shortAddress
import com.bgallagher.rackoon.core.bookmarkItems
import com.bgallagher.rackoon.core.status
import com.bgallagher.rackoon.core.summary
import com.bgallagher.rackoon.core.usageText
import com.bgallagher.rackoon.ui.theme.Rackoon
import com.bgallagher.rackoon.ui.theme.RackoonIcons
import kotlinx.coroutines.delay

@Composable
fun DockerScreen(vm: AppViewModel, server: Server, wide: Boolean, readOnly: Boolean) {
    val ui by vm.docker.collectAsStateWithLifecycle()
    val openName by vm.openStack.collectAsStateWithLifecycle()
    BackHandler(enabled = openName != null) { vm.openStack(null) }
    when (val state = ui) {
        DockerUi.Loading -> DockerLoading()
        DockerUi.NotInstalled -> Message("Docker isn't installed", "Rackoon didn't find Docker on ${server.name}. Install it and this page will fill in.", "Check again", vm::refreshDockerNow)
        is DockerUi.Failed -> if (state.unreachable) Unreachable(server, state.message, vm::refreshDockerNow)
        else Message("Docker isn't responding", state.message, "Try again", vm::refreshDockerNow)
        is DockerUi.Ready -> {
            val stack = openName?.let { n -> state.stacks.firstOrNull { it.name == n } }
            if (openName != null && stack == null) LaunchedEffect(openName) { vm.openStack(null) }   // the stack went away
            if (stack != null) StackDetail(vm, server, stack, state, readOnly, onBack = { vm.openStack(null) })
            else if (state.snapshot.containers.isEmpty()) Message(
                "No containers found", "Docker is running on ${server.name}, but there are no containers yet. Stacks appear here once their containers exist.", "Scan again", vm::refreshDockerNow,
            )
            else StackList(state, vm.favicons, readOnly, onOpen = { vm.openStack(it.name) }, onBookmark = { vm.openBookmarkSheet(it.name) }, onAdd = vm::openAddContainer, onRefresh = vm::refreshDockerNow)
        }
    }
}

// MARK: list

@Composable
private fun StackList(ui: DockerUi.Ready, favicons: com.bgallagher.rackoon.data.FaviconStore, readOnly: Boolean, onOpen: (DockerStack) -> Unit, onBookmark: (DockerStack) -> Unit, onAdd: () -> Unit, onRefresh: () -> Unit) {
    var refreshing by remember { mutableStateOf(false) }
    LaunchedEffect(refreshing) { if (refreshing) { delay(900); refreshing = false } }
    val stacks = ui.stacks
    val addresses = remember(ui.snapshot) { ui.snapshot.bookmarkItems.map { it.bookmark.href }.distinct() }
    LaunchedEffect(addresses) { favicons.ensure(addresses) }
    // Which stacks can take a bookmark is worked out once per snapshot, not for every card on every recomposition.
    val bookmarkable = remember(ui.snapshot) { ui.snapshot.bookmarkableStacks.map { it.name }.toSet() }
    PullToRefreshBox(isRefreshing = refreshing, onRefresh = { refreshing = true; onRefresh() }, modifier = Modifier.fillMaxSize()) {
        // One column on a phone; more on a tablet or foldable.
        LazyVerticalGrid(
            GridCells.Adaptive(minSize = 340.dp), Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 16.dp, end = 16.dp, bottom = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Column(Modifier.padding(bottom = 4.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Docker", fontSize = 28.sp, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary, modifier = Modifier.weight(1f))
                        // The design's "Add container" pill. Disabled with a reason in Read-only mode (it changes the server).
                        Text(
                            "Add container", fontSize = 14.sp, fontWeight = FontWeight.Medium,
                            color = if (readOnly) Rackoon.colors.textMuted else Rackoon.colors.textPrimary,
                            modifier = Modifier.clip(RoundedCornerShape(20.dp)).background(Rackoon.colors.selection).clickable(enabled = !readOnly, onClick = onAdd).padding(horizontal = 16.dp, vertical = 11.dp),
                        )
                    }
                    Text(ui.snapshot.summary(), fontSize = 13.sp, color = Rackoon.colors.textSecondary, modifier = Modifier.padding(top = 2.dp))
                    if (ui.error != null) Text("Showing the last reading. ${ui.error}", color = Rackoon.colors.warn, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
                }
            }
            items(stacks, key = { it.name }) { stack ->
                StackCard(stack, favicons, onClick = { onOpen(stack) }, onBookmark = if (stack.name in bookmarkable) ({ onBookmark(stack) }) else null)
            }
        }
    }
}

@Composable
private fun StackCard(stack: DockerStack, favicons: com.bgallagher.rackoon.data.FaviconStore, onClick: () -> Unit, onBookmark: (() -> Unit)?) {
    val c = Rackoon.colors
    val status = stack.status()
    val unhealthy = stack.unhealthyCount > 0
    val shape = RoundedCornerShape(14.dp)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(c.card).border(1.dp, if (unhealthy) c.danger.copy(alpha = 0.5f) else c.border, shape)
            .clickable(onClick = onClick).padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            // Name and file share the space left of the status, so the status and its dot always end at the right edge.
            Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                SiteIcon(stack.name, stack.containers.firstNotNullOfOrNull { it.bookmark?.href }, 28.dp, favicons)
                Text(stack.name, fontSize = 16.sp, fontWeight = FontWeight.Medium, color = c.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                stack.configFileName?.let { Text(it, fontSize = 12.sp, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false)) }
            }
            if (status.text.isNotEmpty()) Text(status.text, fontSize = 13.sp, color = severityColor(status.severity))
            StatusDot(severityColor(status.severity, dot = true))
            if (onBookmark != null) {
                // Its own button, so tapping it never also opens the stack.
                Box(Modifier.size(40.dp).padding(start = 0.dp).clip(CircleShape).clickable(onClick = onBookmark), contentAlignment = Alignment.Center) {
                    Icon(
                        if (stack.hasBookmark) RackoonIcons.BookmarkFilled else RackoonIcons.Bookmark,
                        if (stack.hasBookmark) "Edit bookmark for ${stack.name}" else "Add bookmark for ${stack.name}",
                        tint = if (stack.hasBookmark) c.accent else c.textMuted, modifier = Modifier.size(20.dp),
                    )
                }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            stack.containers.forEach { ct ->
                Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(ct.service ?: ct.name, color = if (ct.isUnhealthy) c.danger else c.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Text(ct.usageText(Format::bytes), fontFamily = MonoFamily, fontSize = 12.sp, color = if (ct.isUnhealthy) c.danger else c.textSecondary)
                }
            }
        }
        LinkRow(stack)
    }
}

/** The stack's site: opens in the browser, with where it works (Local, Tailscale, Public). */
@Composable
internal fun LinkRow(stack: DockerStack, big: Boolean = false) {
    val first = stack.bookmarkLinks.firstOrNull() ?: return
    val c = Rackoon.colors
    val uri = LocalUriHandler.current
    val more = stack.bookmarkLinks.size - 1
    Column {
        if (!big) HorizontalDivider(color = c.border, modifier = Modifier.padding(bottom = 4.dp))
        Row(
            Modifier.fillMaxWidth().height(36.dp).clip(RoundedCornerShape(8.dp)).clickable { runCatching { uri.openUri(first.href) } },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(RackoonIcons.External, "Open", tint = c.accent, modifier = Modifier.size(14.dp))
            Text(first.shortAddress() + if (more > 0) "  +$more more" else "", color = c.accent, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            ScopeTag(first.href)
        }
    }
}

/** The theme colour family for a link's scope: Local, Tailscale and Public each have their own, and none of them is a status colour. */
@Composable
internal fun scopeRole(scope: LinkScope): com.bgallagher.rackoon.ui.theme.ColorRole = when (scope) {
    LinkScope.LOCAL -> Rackoon.colors.scopeLocal
    LinkScope.TAILSCALE -> Rackoon.colors.scopeTailscale
    LinkScope.PUBLIC -> Rackoon.colors.scopePublic
}

@Composable
private fun ScopeTag(href: String) {
    val scope = LinkScope.of(href)
    Text(scope.title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = scopeRole(scope).label)
}

@Composable
internal fun severityColor(s: StackSeverity, dot: Boolean = false): Color = when (s) {
    StackSeverity.OK -> Rackoon.colors.ok
    StackSeverity.WARNING -> Rackoon.colors.warn
    StackSeverity.DANGER -> Rackoon.colors.danger
    StackSeverity.IDLE -> if (dot) Rackoon.colors.idle else Rackoon.colors.textMuted
}

/** A tinted letter standing in for a site icon: one of the theme's six series colours, picked from the name so a stack keeps it. */
@Composable
fun LetterBadge(name: String, size: androidx.compose.ui.unit.Dp, modifier: Modifier = Modifier) {
    val series = Rackoon.colors.series
    val role = series[LetterTile.slot(name, series.size)]
    Box(modifier.size(size).clip(RoundedCornerShape(size * 0.27f)).background(role.fill), contentAlignment = Alignment.Center) {
        Text(LetterTile.letter(name), color = role.onFill, fontSize = (size.value * 0.5f).sp, fontWeight = FontWeight.Bold)
    }
}

// MARK: states

@Composable
private fun DockerLoading() {
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Docker", fontSize = 28.sp, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            StatusDot(Rackoon.colors.warn)
            Text("Reading containers…", color = Rackoon.colors.textSecondary, fontSize = 13.sp)
        }
        repeat(3) { RCard(Modifier.fillMaxWidth().height(110.dp)) { Box(Modifier.fillMaxSize()) } }
    }
}

@Composable
private fun Message(title: String, body: String, button: String, onClick: () -> Unit) {
    val c = Rackoon.colors
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Docker", fontSize = 28.sp, fontWeight = FontWeight.Medium, color = c.textPrimary)
        RCard(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(title, fontSize = 18.sp, fontWeight = FontWeight.Medium, color = c.textPrimary)
                Text(body, color = c.textSecondary, lineHeight = 21.sp)
            }
        }
        PrimaryButton(button, onClick, Modifier.fillMaxWidth())
    }
}

/** The design's "Cannot reach" board: what failed, and the three things to check on a Tailscale setup. */
@Composable
private fun Unreachable(server: Server, message: String, onRetry: () -> Unit) {
    val c = Rackoon.colors
    val context = LocalContext.current
    val tailscale = remember { context.packageManager.getLaunchIntentForPackage("com.tailscale.ipn") }
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Docker", fontSize = 28.sp, fontWeight = FontWeight.Medium, color = c.textPrimary)
        RCard(Modifier.fillMaxWidth(), borderColor = c.danger) {
            Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    StatusDot(c.danger, 10)
                    Text("Cannot reach ${server.name}", fontSize = 18.sp, fontWeight = FontWeight.Medium, color = c.textPrimary)
                }
                Text(message, color = c.textSecondary, lineHeight = 21.sp)
            }
        }
        Text("Is Tailscale connected?", fontSize = 16.sp, fontWeight = FontWeight.Medium, color = c.textPrimary)
        RCard(Modifier.fillMaxWidth()) {
            Column {
                listOf("Tailscale is signed in on this phone", "The server shows as online in your tailnet", "SSH is running on the server (port 22)").forEachIndexed { i, t ->
                    if (i > 0) HorizontalDivider(color = c.border)
                    Row(Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Box(Modifier.size(8.dp).clip(CircleShape).background(c.idle))
                        Text(t, color = c.textPrimary, lineHeight = 20.sp)
                    }
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (tailscale != null) SecondaryButton("Open Tailscale", { runCatching { context.startActivity(tailscale.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } }, Modifier.weight(1f))
            PrimaryButton("Retry", onRetry, Modifier.weight(1f))
        }
    }
}

/**
 * A service's site icon when the phone has fetched one for [href], else the letter tile. Tapping it fetches a fresh icon
 * (only when there is an address to fetch from).
 */
@Composable
fun SiteIcon(name: String, href: String?, size: androidx.compose.ui.unit.Dp, favicons: com.bgallagher.rackoon.data.FaviconStore) {
    val origin = remember(href) { href?.let(favicons::origin) }
    val images by favicons.images.collectAsStateWithLifecycle()
    val fetching by favicons.fetching.collectAsStateWithLifecycle()
    val image = origin?.let { images[it] }
    val tap = if (href != null && origin != null) Modifier.clip(RoundedCornerShape(size * 0.27f)).clickable { favicons.refresh(href) } else Modifier
    when {
        origin != null && origin in fetching && image == null -> Box(Modifier.size(size), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(Modifier.size(size * 0.55f), strokeWidth = 2.dp, color = Rackoon.colors.accent)
        }
        image != null -> androidx.compose.foundation.Image(
            image, contentDescription = "Site icon for $name", modifier = Modifier.size(size).then(tap).clip(RoundedCornerShape(size * 0.22f)),
            contentScale = androidx.compose.ui.layout.ContentScale.Fit,
        )
        else -> LetterBadge(name, size, tap)
    }
}
