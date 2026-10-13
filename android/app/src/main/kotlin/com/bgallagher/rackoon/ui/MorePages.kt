package com.bgallagher.rackoon.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.bgallagher.rackoon.AppViewModel
import com.bgallagher.rackoon.core.AutoReadOnly
import com.bgallagher.rackoon.ui.theme.Rackoon
import com.bgallagher.rackoon.ui.theme.RackoonIcons

/** The pages behind More > Terminal, Safety and About. */
@Composable
fun MorePageScreen(vm: AppViewModel, page: AppViewModel.MorePage) {
    val back = { vm.showMorePage(null) }
    BackHandler(onBack = back)
    val c = Rackoon.colors
    Column(Modifier.fillMaxSize().background(c.background).statusBarsPadding()) {
        Row(Modifier.height(64.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconTap(RackoonIcons.ChevronLeft, "Back to More", c.textPrimary, back)
            Text(
                when (page) { AppViewModel.MorePage.Terminal -> "Terminal"; AppViewModel.MorePage.Safety -> "Safety"; AppViewModel.MorePage.About -> "About" },
                fontSize = 18.sp, fontWeight = FontWeight.Medium, color = c.textPrimary,
            )
        }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            when (page) {
                AppViewModel.MorePage.Terminal -> TerminalSettings(vm)
                AppViewModel.MorePage.Safety -> SafetySettings(vm)
                AppViewModel.MorePage.About -> About()
            }
        }
    }
}

@Composable
private fun TerminalSettings(vm: AppViewModel) {
    val c = Rackoon.colors
    val size by vm.terminalFontSize.collectAsStateWithLifecycle()
    val highlight by vm.highlightOutput.collectAsStateWithLifecycle()
    RCard(Modifier.fillMaxWidth()) {
        Column {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Font size", fontWeight = FontWeight.Medium, color = c.textPrimary)
                    Text("$size sp. The terminal tab also has A− and A+.", fontSize = 12.sp, color = c.textMuted)
                }
                SecondaryButton("A−", { vm.changeFontSize(-1) }, Modifier.padding(end = 8.dp))
                SecondaryButton("A+", { vm.changeFontSize(1) })
            }
            Row(Modifier.fillMaxWidth().height(1.dp).background(c.border)) {}
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Highlight terminal output", fontWeight = FontWeight.Medium, color = c.textPrimary)
                    Text("Colour errors, warnings, IP addresses and high percentages", fontSize = 12.sp, color = c.textMuted)
                }
                Switch(highlight, vm::setHighlight)
            }
        }
    }
}

@Composable
private fun SafetySettings(vm: AppViewModel) {
    val c = Rackoon.colors
    val start by vm.startReadOnly.collectAsStateWithLifecycle()
    val auto by vm.autoReadOnly.collectAsStateWithLifecycle()
    RCard(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Start in Read-only", fontWeight = FontWeight.Medium, color = c.textPrimary)
                Text("Every launch begins with changes blocked, even if you left them allowed.", fontSize = 12.sp, lineHeight = 17.sp, color = c.textMuted)
            }
            Switch(start, vm::setStartReadOnly)
        }
    }
    Text("TURN READ-ONLY BACK ON", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.6.sp, color = c.textMuted, modifier = Modifier.padding(start = 4.dp))
    RCard(Modifier.fillMaxWidth()) {
        Column {
            AutoReadOnly.entries.forEachIndexed { i, mode ->
                if (i > 0) Row(Modifier.fillMaxWidth().height(1.dp).background(c.border)) {}
                Row(
                    Modifier.fillMaxWidth().clickable { vm.setAutoReadOnly(mode) }.padding(horizontal = 8.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RadioButton(auto == mode, { vm.setAutoReadOnly(mode) })
                    Text(mode.label, color = c.textPrimary)
                }
            }
        }
    }
    Text(
        "Idle means nobody has touched the app. A running action is never interrupted: Read-only only switches back on once it has finished.",
        fontSize = 12.sp, lineHeight = 17.sp, color = c.textMuted, modifier = Modifier.padding(horizontal = 4.dp),
    )
}

@Composable
private fun About() {
    val c = Rackoon.colors
    val uri = LocalUriHandler.current
    val context = LocalContext.current
    val version = runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull().orEmpty()
    RCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Rackoon $version", fontSize = 18.sp, fontWeight = FontWeight.Medium, color = c.textPrimary)
            Text("Manage your servers over plain SSH. Nothing to install on them.", color = c.textSecondary, lineHeight = 20.sp)
            Text("Developed by Brian Gallagher", color = c.textSecondary)
        }
    }
    RCard(Modifier.fillMaxWidth()) {
        Column {
            MoreLink("Source and releases", "github.com/bgallagher/rackoon") { runCatching { uri.openUri("https://github.com/bgallagher/rackoon") } }
        }
    }
    Text("Terminal themes come from the iTerm2-Color-Schemes collection (MIT).", fontSize = 12.sp, color = c.textMuted, modifier = Modifier.padding(horizontal = 4.dp))
}

@Composable
private fun MoreLink(title: String, subtitle: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary)
            Text(subtitle, fontSize = 12.sp, color = Rackoon.colors.textMuted)
        }
        androidx.compose.material3.Icon(RackoonIcons.External, null, tint = Rackoon.colors.textMuted)
    }
}
