package com.bgallagher.rackoon.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bgallagher.rackoon.SettingsForm
import com.bgallagher.rackoon.core.ServerInput
import com.bgallagher.rackoon.data.AuthKind
import com.bgallagher.rackoon.ui.theme.Rackoon
import com.bgallagher.rackoon.ui.theme.RackoonIcons
import java.text.DateFormat
import java.util.Date

/** More > Server settings: rename, change the address and the sign-in, forget the trusted host key, remove the server. */
@Composable
fun ServerSettingsScreen(
    form: SettingsForm, onChange: ((SettingsForm) -> SettingsForm) -> Unit, onSave: () -> Unit, onBack: () -> Unit,
    onForgetKey: () -> Unit, onRemove: () -> Unit, onTrust: () -> Unit, onDeclineTrust: () -> Unit,
) {
    BackHandler(onBack = onBack)
    val c = Rackoon.colors
    var confirmForget by remember { mutableStateOf(false) }
    var confirmRemove by remember { mutableStateOf(false) }
    val server = form.server
    Column(Modifier.fillMaxSize().background(c.background).statusBarsPadding().imePadding()) {
        Row(Modifier.height(64.dp).padding(start = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconTap(RackoonIcons.ChevronLeft, "Back", c.textPrimary, onBack)
            Text("Server settings", fontSize = 18.sp, fontWeight = FontWeight.Medium, color = c.textPrimary)
        }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Field("Name", form.name, server.host, enabled = !form.busy) { v -> onChange { it.copy(name = v, error = null) } }
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                SectionLabel("Address")
                Field("Host", form.host, "example.com, 203.0.113.7 or a Tailscale name", mono = true, enabled = !form.busy, keyboard = KeyboardType.Uri) { v -> onChange { it.copy(host = v, error = null) } }
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Box(Modifier.weight(1f)) { Field("User", form.user, "root", mono = true, enabled = !form.busy) { v -> onChange { it.copy(user = v, error = null) } } }
                    Box(Modifier.weight(0.6f)) { Field("Port", form.port, "22", mono = true, enabled = !form.busy, keyboard = KeyboardType.Number) { v -> onChange { it.copy(port = v, error = null) } } }
                }
                // Only once something is wrong: an untouched form is not yet wrong.
                ServerInput.problem(form.host, form.user, form.port)?.let { Text(it, color = c.warn, fontSize = 12.sp) }
            }
            AuthSection(form.auth, enabled = !form.busy, savedKeyName = form.currentKeyName.takeIf { form.currentKind == AuthKind.Key }) { a ->
                onChange { it.copy(auth = a, authChanged = true, error = null) }
            }
            RCard(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionLabel("Trusted host key")
                    val key = form.hostKey
                    if (key == null) {
                        Text("Nothing is trusted for this server yet. Rackoon will ask the next time it connects.", color = c.textSecondary, fontSize = 13.sp, lineHeight = 19.sp)
                    } else {
                        Text(key.fingerprint, fontFamily = MonoFamily, fontSize = 13.sp, color = c.textPrimary)
                        Text("${key.keyType} · trusted ${DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(key.trustedAt))}", fontSize = 12.sp, color = c.textMuted)
                        SecondaryButton("Forget host key", { confirmForget = true }, Modifier.fillMaxWidth())
                        Text("Use this only after the server's key really changed (a reinstall). Rackoon will show the new fingerprint and ask you to trust it.", fontSize = 12.sp, color = c.textMuted, lineHeight = 17.sp)
                    }
                }
            }
            SecondaryButton("Remove server…", { confirmRemove = true }, Modifier.fillMaxWidth())
        }
        // Pinned above the buttons so a refusal is never hidden below the fold of a long form.
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (form.busy) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = c.accent)
                    Text("Trying the connection…", color = c.textSecondary, fontSize = 13.sp)
                }
            }
            form.error?.let { Text(it, color = c.danger, fontSize = 13.sp, lineHeight = 19.sp) }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp).navigationBarsPadding(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            SecondaryButton("Cancel", onBack, Modifier.weight(1f))
            PrimaryButton("Save", onSave, Modifier.weight(1f), enabled = !form.busy && ServerInput.problem(form.host, form.user, form.port) == null)
        }
    }
    form.trust?.let { TrustSheet(host = form.host.trim(), key = it, onTrust = onTrust, onCancel = onDeclineTrust) }
    if (confirmForget) {
        AlertDialog(
            onDismissRequest = { confirmForget = false }, containerColor = c.sidebar,
            title = { Text("Forget this host key?") },
            text = { Text("Rackoon will ask you to trust the server's key again the next time it connects.") },
            confirmButton = { TextButton({ confirmForget = false; onForgetKey() }) { Text("Forget", color = c.danger) } },
            dismissButton = { TextButton({ confirmForget = false }) { Text("Cancel") } },
        )
    }
    if (confirmRemove) {
        AlertDialog(
            onDismissRequest = { confirmRemove = false }, containerColor = c.sidebar,
            title = { Text("Remove ${server.name}?") },
            text = { Text("Its saved sign-in, trusted host key and open terminals are removed from this phone. Nothing changes on the server.") },
            confirmButton = { TextButton({ confirmRemove = false; onRemove() }) { Text("Remove", color = c.danger) } },
            dismissButton = { TextButton({ confirmRemove = false }) { Text("Cancel") } },
        )
    }
}
