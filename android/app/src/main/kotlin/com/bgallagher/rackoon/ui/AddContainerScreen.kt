package com.bgallagher.rackoon.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.bgallagher.rackoon.AppViewModel
import com.bgallagher.rackoon.core.AddContainerDraft
import com.bgallagher.rackoon.core.AddState
import com.bgallagher.rackoon.core.AddTarget
import com.bgallagher.rackoon.core.ContainerSpec
import com.bgallagher.rackoon.core.EditorCheckRow
import com.bgallagher.rackoon.core.EnvRow
import com.bgallagher.rackoon.core.PortRow
import com.bgallagher.rackoon.core.RestartPolicy
import com.bgallagher.rackoon.core.VolumeRow
import com.bgallagher.rackoon.ui.theme.LocalTerminalTheme
import com.bgallagher.rackoon.ui.theme.Rackoon
import com.bgallagher.rackoon.ui.theme.RackoonIcons

/**
 * Add container: a form (or a pasted compose.yaml) that becomes a new stack, or one more service in an existing stack. The server
 * checks the files, the image, the ports and the name before anything is written; the files are shown below, read-only.
 */
@Composable
fun AddContainerScreen(vm: AppViewModel, readOnly: Boolean) {
    val c = Rackoon.colors
    val draft = vm.draft() ?: return
    val s by vm.addState.collectAsStateWithLifecycle()
    val confirmLeave by vm.addConfirmLeave.collectAsStateWithLifecycle()
    BackHandler(onBack = vm::closeAddContainer)
    val rows = draft.rows(s)
    val blocked = draft.deployBlockedReason(s)
    val pasted = s.paste && s.target == AddTarget.NEW_STACK
    val spec = s.spec
    val existingNames = draft.existingCandidates.map { it.name }

    Column(Modifier.fillMaxSize().background(c.background).statusBarsPadding().imePadding()) {
        Row(Modifier.height(56.dp).padding(end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            IconTap(RackoonIcons.ChevronLeft, "Back to Docker", c.textPrimary, vm::closeAddContainer)
            Text("Add container", fontSize = 18.sp, fontWeight = FontWeight.Medium, color = c.textPrimary)
        }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            if (readOnly) ReadOnlyBanner(onTurnOff = vm::toggleReadOnly)

            Segmented(listOf("New stack" to (s.target == AddTarget.NEW_STACK), "Existing stack" to (s.target == AddTarget.EXISTING))) { i ->
                draft.setTarget(if (i == 0) AddTarget.NEW_STACK else AddTarget.EXISTING)
            }

            if (s.target == AddTarget.NEW_STACK) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Field("Stack name", s.stackName, "media", mono = true) { draft.setStackName(it) }
                    draft.newStackNameProblem(s)?.let { Text(it, color = c.dangerRole.label, fontSize = 12.sp) } ?: if (s.stackName.isBlank()) Text("Required", color = c.textMuted, fontSize = 12.sp) else Unit
                }
                Field("Folder on the server", s.folder, "/opt/stacks", mono = true) { draft.setFolder(it) }
                s.stackName.takeIf { it.isNotEmpty() }?.let { Text("Creates ${draft.plan(s).directory ?: "${s.folder}/$it"}", color = c.textMuted, fontSize = 12.sp, fontFamily = MonoFamily) }
                // The form is the main path; pasting a file is the alternative, so it is a quiet text button, not a second tab bar.
                androidx.compose.material3.TextButton({ draft.setPaste(!pasted) }, contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 4.dp)) {
                    Text(if (pasted) "Use the form instead" else "Paste compose.yaml instead", color = c.accent, fontWeight = FontWeight.Medium)
                }
            } else {
                if (existingNames.isEmpty()) Text("No stack on this server has a compose file Rackoon can edit.", color = c.textMuted)
                else Picker("Stack", s.existingName ?: "Choose a stack", existingNames, enabled = !s.working) { draft.chooseExisting(it) }
                if (s.existing?.error != null) Text(s.existing?.error.orEmpty(), color = c.danger, fontSize = 13.sp)
            }

            if (pasted) {
                MultiLine("compose.yaml", s.pasteCompose, "services:\n  app:\n    image: nginx:alpine") { draft.setPasteCompose(it) }
                MultiLine(".env (optional)", s.pasteEnv, "KEY=value") { draft.setPasteEnv(it) }
                val missing = draft.missingVariables(s)
                if (missing.isNotEmpty()) {
                    RCard(Modifier.fillMaxWidth(), borderColor = c.warn) {
                        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("Variables with no value: ${missing.joinToString(", ")}", color = c.textPrimary, fontSize = 13.sp, lineHeight = 19.sp)
                            SecondaryButton("Add them to .env", draft::addMissingVariables)
                        }
                    }
                }
            } else {
                Form(spec, draft)
            }

            Checks(rows)

            if (!pasted || s.pasteCompose.isNotEmpty()) Preview(draft, s)

            s.notice?.let { Text(it, color = c.danger, fontSize = 13.sp, lineHeight = 19.sp) }
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(c.border))
        Column(Modifier.fillMaxWidth().background(c.sidebar).padding(horizontal = 16.dp, vertical = 8.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(blocked ?: "Checked on the server before anything is written.", color = c.textMuted, fontSize = 12.sp, lineHeight = 17.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (s.working) CircularProgressIndicator(Modifier.size(24.dp).align(Alignment.CenterVertically), strokeWidth = 2.dp, color = c.accent)
                SecondaryButton(if (s.target == AddTarget.NEW_STACK) "Save" else "Add", { vm.requestAddDeploy(start = false) }, Modifier.weight(1f), enabled = blocked == null)
                PrimaryButton(if (s.target == AddTarget.NEW_STACK) "Create and start" else "Add and start", { vm.requestAddDeploy(start = true) }, Modifier.weight(1.4f), enabled = blocked == null)
            }
        }
    }
    if (confirmLeave) {
        AlertDialog(
            onDismissRequest = vm::keepAdding, containerColor = c.sidebar,
            title = { Text("Discard this container?") }, text = { Text("What you entered hasn't been created. Leaving now throws it away.") },
            confirmButton = { TextButton(vm::closeAddNow) { Text("Discard", color = c.danger) } },
            dismissButton = { TextButton(vm::keepAdding) { Text("Keep editing") } },
        )
    }
}

@Composable
private fun Form(spec: ContainerSpec, draft: AddContainerDraft) {
    val c = Rackoon.colors
    fun update(new: ContainerSpec) = draft.setSpec(new)
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Field("Container name", spec.name, "uptime-kuma", mono = true) { update(spec.copy(name = it)) }
        spec.nameProblem?.let { Text(it, color = c.dangerRole.label, fontSize = 12.sp) } ?: if (spec.name.isBlank()) Text("Required", color = c.textMuted, fontSize = 12.sp) else Unit
    }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Field("Image", spec.image, "louislam/uptime-kuma:1", mono = true, keyboard = KeyboardType.Uri) { update(spec.copy(image = it)) }
        spec.imageProblem?.let { Text(it, color = c.dangerRole.label, fontSize = 12.sp) } ?: if (spec.image.isBlank()) Text("Required", color = c.textMuted, fontSize = 12.sp) else Unit
    }

    Section("Ports", "host : container", "Host port" to "Container port") {
        spec.ports.forEachIndexed { i, row ->
            RowLine(
                { Field("", row.host, "3001", mono = true, keyboard = KeyboardType.Ascii) { update(spec.copy(ports = spec.ports.replace(i, row.copy(host = it)))) } },
                { Field("", row.container, "3001", mono = true, keyboard = KeyboardType.Number) { update(spec.copy(ports = spec.ports.replace(i, row.copy(container = it)))) } },
                onRemove = { update(spec.copy(ports = spec.ports.without(i).ifEmpty { listOf(PortRow()) })) },
            )
            ContainerSpec.portProblem(row)?.let { Text(it, color = c.dangerRole.label, fontSize = 12.sp) }
        }
        AddRow("Add port") { update(spec.copy(ports = spec.ports + PortRow())) }
    }
    Section("Volumes", "source : container path", "Source" to "Path in container") {
        spec.volumes.forEachIndexed { i, row ->
            RowLine(
                { Field("", row.source, "./data", mono = true) { update(spec.copy(volumes = spec.volumes.replace(i, row.copy(source = it)))) } },
                { Field("", row.target, "/app/data", mono = true) { update(spec.copy(volumes = spec.volumes.replace(i, row.copy(target = it)))) } },
                onRemove = { update(spec.copy(volumes = spec.volumes.without(i).ifEmpty { listOf(VolumeRow()) })) },
            )
            ContainerSpec.volumeProblem(row)?.let { Text(it, color = c.dangerRole.label, fontSize = 12.sp) }
        }
        AddRow("Add volume") { update(spec.copy(volumes = spec.volumes + VolumeRow())) }
    }
    Section("Environment", "name = value, saved in .env", "Name" to "Value") {
        spec.env.forEachIndexed { i, row ->
            RowLine(
                { Field("", row.key, "TZ", mono = true) { update(spec.copy(env = spec.env.replace(i, row.copy(key = it)))) } },
                { Field("", row.value, "Europe/Dublin", mono = true) { update(spec.copy(env = spec.env.replace(i, row.copy(value = it)))) } },
                onRemove = { update(spec.copy(env = spec.env.without(i).ifEmpty { listOf(EnvRow()) })) },
            )
            ContainerSpec.envProblem(row)?.let { Text(it, color = c.dangerRole.label, fontSize = 12.sp) }
        }
        AddRow("Add variable") { update(spec.copy(env = spec.env + EnvRow())) }
    }
    Column {
        Text("Restart policy", color = c.textSecondary, fontSize = 13.sp, modifier = Modifier.padding(start = 2.dp, bottom = 8.dp))
        Segmented(RestartPolicy.entries.map { it.label to (it == spec.restart) }) { update(spec.copy(restart = RestartPolicy.entries[it])) }
    }
}

private fun <T> List<T>.replace(i: Int, item: T) = mapIndexed { index, old -> if (index == i) item else old }
private fun <T> List<T>.without(i: Int) = filterIndexed { index, _ -> index != i }

@Composable
private fun Section(title: String, hint: String, columns: Pair<String, String>, content: @Composable () -> Unit) {
    val c = Rackoon.colors
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, color = c.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.Medium)
            Text(hint, color = c.textMuted, fontSize = 12.sp)
        }
        // Visible labels over the two columns, so a filled-in row is never a bare pair of boxes.
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(columns.first, color = c.textSecondary, fontSize = 12.sp, modifier = Modifier.weight(1f).padding(start = 2.dp))
            Text(columns.second, color = c.textSecondary, fontSize = 12.sp, modifier = Modifier.weight(1f).padding(start = 2.dp))
            Spacer(Modifier.width(48.dp))
        }
        content()
    }
}

@Composable
private fun RowLine(first: @Composable () -> Unit, second: @Composable () -> Unit, onRemove: (() -> Unit)?) {
    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.weight(1f)) { first() }
        Box(Modifier.weight(1f)) { second() }
        Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) { if (onRemove != null) IconTap(RackoonIcons.Close, "Remove row", Rackoon.colors.textMuted, onRemove) }
    }
}

@Composable
private fun AddRow(label: String, onClick: () -> Unit) {
    Row(Modifier.height(44.dp).clip(RoundedCornerShape(22.dp)).clickable(onClick = onClick).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        androidx.compose.material3.Icon(RackoonIcons.Plus, null, tint = Rackoon.colors.accent, modifier = Modifier.size(16.dp))
        Text(label, color = Rackoon.colors.accent, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun Segmented(options: List<Pair<String, Boolean>>, onPick: (Int) -> Unit) {
    val c = Rackoon.colors
    val shape = RoundedCornerShape(12.dp)
    Row(Modifier.fillMaxWidth().clip(shape).border(1.dp, c.border, shape)) {
        options.forEachIndexed { i, (label, on) ->
            Box(
                Modifier.weight(1f).height(44.dp).background(if (on) c.selection else Color.Transparent).clickable { onPick(i) }.padding(horizontal = 4.dp),
                contentAlignment = Alignment.Center,
            ) { Text(label, fontSize = 12.sp, lineHeight = 15.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal, color = if (on) c.textPrimary else c.textSecondary, maxLines = 2) }
        }
    }
}

@Composable
private fun MultiLine(label: String, value: String, placeholder: String, onChange: (String) -> Unit) {
    val c = Rackoon.colors
    Column {
        Text(label, color = c.textSecondary, fontSize = 13.sp, modifier = Modifier.padding(start = 2.dp, bottom = 6.dp))
        androidx.compose.material3.OutlinedTextField(
            value, onChange, modifier = Modifier.fillMaxWidth().heightIn(min = 140.dp, max = 320.dp),
            placeholder = { Text(placeholder, color = c.textMuted, fontFamily = MonoFamily, fontSize = 13.sp) },
            textStyle = androidx.compose.ui.text.TextStyle(fontSize = 13.sp, fontFamily = MonoFamily, color = c.textPrimary),
            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Ascii),
            shape = RoundedCornerShape(12.dp),
            colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                focusedBorderColor = c.accent, unfocusedBorderColor = c.border, focusedContainerColor = c.sidebar, unfocusedContainerColor = c.sidebar, cursorColor = c.textPrimary,
            ),
        )
    }
}

@Composable
private fun Checks(rows: List<EditorCheckRow>) {
    val c = Rackoon.colors
    if (rows.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Checks", color = c.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.Medium)
        RCard(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                rows.forEach { row ->
                    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Box(Modifier.width(16.dp), contentAlignment = Alignment.Center) {
                            when (row.state) {
                                EditorCheckRow.State.RUNNING -> CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp, color = c.accent)
                                EditorCheckRow.State.PASS -> Text("✓", color = c.okRole.label, fontWeight = FontWeight.Bold)
                                EditorCheckRow.State.FAIL -> Text("✕", color = c.dangerRole.label, fontWeight = FontWeight.Bold)
                                EditorCheckRow.State.WARN -> Text("!", color = c.warnRole.label, fontWeight = FontWeight.Bold)
                                EditorCheckRow.State.SKIPPED -> Text("–", color = c.textMuted)
                            }
                        }
                        Column {
                            Text(row.title, fontSize = 13.sp, color = if (row.state == EditorCheckRow.State.FAIL) c.danger else if (row.state == EditorCheckRow.State.SKIPPED) c.textMuted else c.textPrimary)
                            if (row.detail.isNotEmpty()) Text(row.detail, fontSize = 12.sp, color = c.textMuted, lineHeight = 17.sp)
                        }
                    }
                }
            }
        }
    }
}

/** What will be written: compose.yaml and .env, read-only (a changed-line band marks what is new). */
@Composable
private fun Preview(draft: AddContainerDraft, s: AddState) {
    val c = Rackoon.colors
    var tab by remember { mutableStateOf(0) }
    val env = draft.envText(s)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Files", color = c.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.Medium)
        Segmented(listOf("compose.yaml" to (tab == 0), (".env" + if (env.isNotEmpty() || s.target == AddTarget.EXISTING) "" else " (none)") to (tab == 1))) { tab = it }
        val text = if (tab == 0) draft.composeText(s) else env
        CodeEditor(
            text = text, onChange = {}, env = tab == 1, readOnly = true, changedLines = draft.changedLines(s, env = tab == 1), errorLines = emptySet(),
            theme = LocalTerminalTheme.current, modifier = Modifier.fillMaxWidth().heightIn(min = 120.dp, max = 300.dp).clip(RoundedCornerShape(12.dp)),
        )
        Text(
            if (s.target == AddTarget.NEW_STACK) "A new folder with these files is created. Nothing is written until you confirm." else "Only new lines are added to your file; everything already in it stays as it is.",
            color = c.textMuted, fontSize = 12.sp, lineHeight = 17.sp,
        )
    }
}
