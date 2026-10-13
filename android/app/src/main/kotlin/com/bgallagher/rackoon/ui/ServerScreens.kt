package com.bgallagher.rackoon.ui

import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.ui.platform.LocalContext
import android.provider.OpenableColumns
import com.bgallagher.rackoon.AddForm
import com.bgallagher.rackoon.AuthFields
import com.bgallagher.rackoon.data.AuthKind
import com.bgallagher.rackoon.ssh.HostKeyInfo
import com.bgallagher.rackoon.ssh.TrustedHostKey
import com.bgallagher.rackoon.ui.theme.Rackoon
import com.bgallagher.rackoon.ui.theme.RackoonIcons
import java.text.DateFormat
import java.util.Date

@Composable
fun AddServerScreen(form: AddForm, onChange: ((AddForm) -> AddForm) -> Unit, onConnect: () -> Unit, onCancel: () -> Unit, onTrust: () -> Unit, onDeclineTrust: () -> Unit) {
    form.blocked?.let {
        HostKeyChangedScreen(it.host, it.trusted, it.presented, onBack = onCancel)
        return
    }
    Column(Modifier.fillMaxSize().background(Rackoon.colors.background).statusBarsPadding().imePadding()) {
        Row(Modifier.height(64.dp).padding(start = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconTap(RackoonIcons.Close, "Close", Rackoon.colors.textPrimary, onCancel)
            Text("Add server", fontSize = 18.sp, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary)
        }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Field("Name", form.name, "homelab", enabled = !form.busy) { v -> onChange { it.copy(name = v, error = null) } }
            Column {
                Field("User and host", form.target, "ubuntu@100.64.12.7", mono = true, enabled = !form.busy, keyboard = KeyboardType.Uri) { v -> onChange { it.copy(target = v, error = null) } }
                Text("Hostname, LAN address or Tailscale name. Port 22 unless you add :port.", color = Rackoon.colors.textMuted, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp, start = 2.dp))
            }
            AuthSection(form.auth, enabled = !form.busy) { a -> onChange { it.copy(auth = a, error = null) } }
            RCard(Modifier.fillMaxWidth()) {
                Row(Modifier.padding(horizontal = 14.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top) {
                    Icon(RackoonIcons.Info, null, tint = Rackoon.colors.textSecondary, modifier = Modifier.size(18.dp).padding(top = 1.dp))
                    Text("Nothing is installed on the server. Rackoon connects over SSH and runs standard commands.", color = Rackoon.colors.textSecondary, fontSize = 13.sp, lineHeight = 19.sp)
                }
            }
        }
        // Pinned above the buttons so a refusal is never hidden below the fold of a long form.
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (form.busy) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Rackoon.colors.accent)
                    Text("Connecting. The first connection can take a few seconds.", color = Rackoon.colors.textSecondary, fontSize = 13.sp)
                }
            }
            form.error?.let { Text(it, color = Rackoon.colors.danger, fontSize = 13.sp, lineHeight = 19.sp) }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp).navigationBarsPadding(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            SecondaryButton("Cancel", onCancel, Modifier.weight(1f))
            PrimaryButton("Connect", onConnect, Modifier.weight(1f), enabled = !form.busy && form.target.isNotBlank())
        }
    }
    form.trust?.let { TrustSheet(host = hostOf(form.target), key = it, onTrust = onTrust, onCancel = onDeclineTrust) }
}

private fun hostOf(target: String) = target.substringAfter('@').substringBefore(':')

@Composable
fun Field(label: String, value: String, placeholder: String, mono: Boolean = false, enabled: Boolean = true, keyboard: KeyboardType = KeyboardType.Text, secret: Boolean = false, onChange: (String) -> Unit) {
    Column {
        if (label.isNotEmpty()) Text(label, color = Rackoon.colors.textSecondary, fontSize = 13.sp, modifier = Modifier.padding(start = 2.dp, bottom = 6.dp))
        OutlinedTextField(
            value = value, onValueChange = onChange, enabled = enabled, singleLine = true, modifier = Modifier.fillMaxWidth(),
            placeholder = { Text(placeholder, color = Rackoon.colors.textDim) },
            textStyle = androidx.compose.ui.text.TextStyle(fontSize = 15.sp, fontFamily = if (mono) MonoFamily else null, color = Rackoon.colors.textPrimary),
            keyboardOptions = KeyboardOptions(keyboardType = if (secret) KeyboardType.Password else keyboard, autoCorrectEnabled = false),
            visualTransformation = if (secret) androidx.compose.ui.text.input.PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
            shape = RoundedCornerShape(12.dp),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = Rackoon.colors.accent, unfocusedBorderColor = Rackoon.colors.border,
                focusedContainerColor = Rackoon.colors.sidebar, unfocusedContainerColor = Rackoon.colors.sidebar, cursorColor = Rackoon.colors.textPrimary,
            ),
        )
    }
}

@Composable
private fun AuthRow(name: String, hint: String, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(enabled = enabled, onClick = onClick).padding(horizontal = 12.dp, vertical = 8.dp).alpha(if (enabled) 1f else 0.5f),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        RadioButton(
            selected = selected, onClick = null, enabled = enabled,
            colors = RadioButtonDefaults.colors(selectedColor = Rackoon.colors.accent, unselectedColor = Rackoon.colors.idle),
        )
        Column(Modifier.padding(vertical = 8.dp)) {
            Text(name, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary)
            Text(hint, color = Rackoon.colors.textMuted, fontSize = 12.sp)
        }
    }
}

/**
 * How to sign in: Tailscale SSH (nothing to enter), a private key chosen with the system file picker, or a password.
 * Secrets are kept encrypted on this phone (Android Keystore) and are only held here while the form is open.
 */
@Composable
fun AuthSection(auth: AuthFields, enabled: Boolean, savedKeyName: String? = null, onChange: (AuthFields) -> Unit) {
    val context = LocalContext.current
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            val name = context.contentResolver.query(uri, null, null, null, null)?.use { c ->
                val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (c.moveToFirst() && i >= 0) c.getString(i) else null
            }
            // A private key is a few KB. Refuse to read anything big (the wrong file) into memory.
            val text = context.contentResolver.openInputStream(uri)?.use { it.readNBytes(64 * 1024 + 1) }?.takeIf { it.size <= 64 * 1024 }?.let { String(it) }
            onChange(auth.copy(keyPem = text ?: "", keyName = name))
        }
    }
    Column {
        Text("Sign in with", color = Rackoon.colors.textSecondary, fontSize = 13.sp, modifier = Modifier.padding(start = 2.dp, bottom = 8.dp))
        RCard(Modifier.fillMaxWidth()) {
            Column {
                AuthRow("Tailscale SSH", "No key needed. Uses your tailnet identity.", auth.kind == AuthKind.Tailscale, enabled) { onChange(auth.copy(kind = AuthKind.Tailscale)) }
                Box(Modifier.fillMaxWidth().height(1.dp).background(Rackoon.colors.border))
                AuthRow("SSH key", "A private key file from this phone.", auth.kind == AuthKind.Key, enabled) { onChange(auth.copy(kind = AuthKind.Key)) }
                Box(Modifier.fillMaxWidth().height(1.dp).background(Rackoon.colors.border))
                AuthRow("Password", "The account's password.", auth.kind == AuthKind.Password, enabled) { onChange(auth.copy(kind = AuthKind.Password)) }
            }
        }
        when (auth.kind) {
            AuthKind.Tailscale -> {}
            AuthKind.Password -> Column(Modifier.padding(top = 14.dp)) {
                Field("Password", auth.password, "", enabled = enabled, secret = true) { onChange(auth.copy(password = it)) }
                SecretNote()
            }
            AuthKind.Key -> Column(Modifier.padding(top = 14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                val shown = auth.keyName ?: savedKeyName?.let { "$it (saved)" }
                SecondaryButton(if (shown == null) "Choose private key file" else "Key: $shown. Choose another", { picker.launch(arrayOf("*/*")) }, Modifier.fillMaxWidth())
                Field("Passphrase (if the key has one)", auth.passphrase, "", enabled = enabled, secret = true) { onChange(auth.copy(passphrase = it)) }
                Text("Pick the private key (for example id_ed25519), not the .pub file.", color = Rackoon.colors.textMuted, fontSize = 12.sp)
                SecretNote()
            }
        }
    }
}

@Composable
private fun SecretNote() {
    Text(
        "Stored encrypted on this phone with the Android Keystore. It is only ever sent to this server.",
        color = Rackoon.colors.textMuted, fontSize = 12.sp, lineHeight = 17.sp, modifier = Modifier.padding(top = 6.dp, start = 2.dp),
    )
}

/** First connection: the server's fingerprint, to compare with the server before trusting it. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TrustSheet(host: String, key: HostKeyInfo, onTrust: () -> Unit, onCancel: () -> Unit) {
    ModalBottomSheet(
        onDismissRequest = onCancel, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Rackoon.colors.sidebar, scrimColor = androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.6f),
    ) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 24.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Column {
                Text("Trust this server?", fontSize = 22.sp, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary)
                Text(
                    buildHost(host), color = Rackoon.colors.textSecondary, lineHeight = 21.sp, modifier = Modifier.padding(top = 4.dp),
                )
            }
            Column {
                SectionLabel("${key.algorithmLabel} fingerprint")
                Box(Modifier.padding(top = 6.dp).fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Rackoon.colors.background).padding(14.dp)) {
                    Text(key.fingerprint, fontFamily = MonoFamily, fontSize = 13.sp, lineHeight = 20.sp, color = Rackoon.colors.textPrimary)
                }
            }
            Text("On the server, run ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub to compare.", color = Rackoon.colors.textSecondary, fontSize = 13.sp, lineHeight = 19.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(top = 6.dp)) {
                SecondaryButton("Cancel", onCancel, Modifier.weight(1f))
                PrimaryButton("Trust and connect", onTrust, Modifier.weight(1f))
            }
        }
    }
}

private fun buildHost(host: String) = "First time connecting to $host. Check this fingerprint matches the server before you continue."

/** The server presented a different key: blocked, with no way to accept it from here. */
@Composable
fun HostKeyChangedScreen(host: String, trusted: TrustedHostKey, presented: HostKeyInfo, onBack: () -> Unit) {
    Column(Modifier.fillMaxSize().background(Rackoon.colors.background).statusBarsPadding(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            RCard(Modifier.fillMaxWidth(), borderColor = Rackoon.colors.danger) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        StatusDot(Rackoon.colors.danger, 10)
                        Text("Connection blocked", fontSize = 20.sp, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary)
                    }
                    Text("The host key for $host is different from the one you trusted. Rackoon did not send any credentials.", color = Rackoon.colors.textSecondary, lineHeight = 21.sp)
                }
            }
            val since = DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(trusted.trustedAt))
            KeyBlock("Trusted since $since", trusted.fingerprint, Rackoon.colors.textMuted, Rackoon.colors.textSecondary)
            KeyBlock("Presented now", presented.fingerprint, Rackoon.colors.danger, Rackoon.colors.textPrimary)
            Text(
                "This can happen after a reinstall, but it can also mean someone is intercepting the connection. Rackoon never connects until the key is fixed on your side: confirm the change on the server, then remove the old entry in Server settings.",
                color = Rackoon.colors.textSecondary, fontSize = 13.sp, lineHeight = 19.sp,
            )
        }
        Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp).navigationBarsPadding()) {
            SecondaryButton("Back to servers", onBack, Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun KeyBlock(title: String, fingerprint: String, titleColor: androidx.compose.ui.graphics.Color, valueColor: androidx.compose.ui.graphics.Color) {
    Column {
        SectionLabel(title, titleColor)
        Box(Modifier.padding(top = 6.dp).fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Rackoon.colors.sidebar).padding(horizontal = 16.dp, vertical = 12.dp)) {
            Text(fingerprint, fontFamily = MonoFamily, fontSize = 12.5.sp, lineHeight = 19.sp, color = valueColor)
        }
    }
}

@Composable
fun FirstRunScreen(onDone: () -> Unit) {
    Column(Modifier.fillMaxSize().background(Rackoon.colors.background).statusBarsPadding()) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(top = 48.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Box(Modifier.size(96.dp).clip(RoundedCornerShape(28.dp)).background(Rackoon.colors.card), contentAlignment = Alignment.Center) {
                Text("🦝", fontSize = 44.sp)
            }
            Column {
                Text("Read-only is on", fontSize = 28.sp, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary)
                Text("Rackoon starts in a safe mode so you can look around before changing anything.", color = Rackoon.colors.textSecondary, fontSize = 15.sp, lineHeight = 23.sp, modifier = Modifier.padding(top = 8.dp))
            }
            RCard(Modifier.fillMaxWidth()) {
                Column {
                    Point(Rackoon.colors.ok, "You can read everything", "Overview and other read-only screens work.")
                    Point(Rackoon.colors.idle, "Changes are disabled", "The terminal and anything that changes a server stay off until you turn Read-only off.")
                    Point(Rackoon.colors.warn, "Every change asks first", "Even with Read-only off, you see the exact command before it runs.")
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ReadOnlyChip(on = true, onClick = {}, small = true)
                Text("This chip is always at the top of the screen. Tap it to turn it off.", color = Rackoon.colors.textSecondary, fontSize = 13.sp, lineHeight = 19.sp)
            }
        }
        Column(Modifier.padding(horizontal = 24.dp, vertical = 12.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            PrimaryButton("Got it", onDone, Modifier.fillMaxWidth())
            Text("Shown once", color = Rackoon.colors.textMuted, fontSize = 12.sp)
        }
    }
}

@Composable
private fun Point(dot: androidx.compose.ui.graphics.Color, title: String, body: String) {
    Row(Modifier.padding(horizontal = 16.dp, vertical = 14.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.Top) {
        Box(Modifier.padding(top = 6.dp)) { StatusDot(dot) }
        Column {
            Text(title, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary)
            Text(body, color = Rackoon.colors.textSecondary, fontSize = 13.sp, lineHeight = 19.sp, modifier = Modifier.padding(top = 2.dp))
        }
    }
}
