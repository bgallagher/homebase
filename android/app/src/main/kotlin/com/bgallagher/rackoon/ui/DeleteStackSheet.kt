package com.bgallagher.rackoon.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.height
import com.bgallagher.rackoon.core.DockerStack
import com.bgallagher.rackoon.core.StackRemoval
import com.bgallagher.rackoon.core.StandaloneAction
import com.bgallagher.rackoon.ui.theme.Rackoon

/**
 * Deleting a stack: what is removed, two opt-in extras that lose data (volumes, the stack's folder), the exact command, and for
 * the extras the stack's name typed in, so a stray tap can't wipe data (the design's ConfirmDestructive board).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DeleteStackSheet(stack: DockerStack, serverName: String, user: String, onCancel: () -> Unit, onRun: (StackRemoval) -> Unit) {
    val c = Rackoon.colors
    val folderProblem = remember(stack) { StackRemoval.folderProblem(stack) }
    var removeVolumes by remember { mutableStateOf(false) }
    // On by default so a deleted stack leaves nothing behind (like Dockge); off when the folder can't safely be deleted.
    var deleteFolder by remember { mutableStateOf(folderProblem == null) }
    var typed by remember { mutableStateOf("") }
    val removal = StackRemoval(removeVolumes, deleteFolder && folderProblem == null)
    val command = removal.command(stack).orEmpty()
    val confirmed = !removal.losesData || typed == stack.name
    val n = stack.containers.size

    ModalBottomSheet(
        onDismissRequest = onCancel, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = c.sidebar, scrimColor = Color.Black.copy(alpha = 0.6f),
    ) {
        Column(Modifier.imePadding().padding(horizontal = 20.dp).verticalScroll(rememberScrollState()).padding(bottom = 16.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Column {
                Text("Delete ${stack.name}?", fontSize = 22.sp, fontWeight = FontWeight.Medium, color = c.textPrimary)
                Text(
                    (if (n == 0) "Removes the stack's networks. It has no containers right now." else "Stops and removes its $n container${if (n == 1) "" else "s"} and the networks Compose made for it.") +
                        " Images are kept. Its folder is deleted too unless you untick that below.",
                    color = c.textSecondary, lineHeight = 21.sp, modifier = Modifier.padding(top = 4.dp),
                )
            }
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Option("Also delete its named volumes", "Data kept in Docker volumes is lost for good.", removeVolumes, true) { removeVolumes = it }
                Option(
                    "Also delete its folder on $serverName",
                    folderProblem ?: "${stack.workingDir.orEmpty()} and everything in it: compose.yaml, .env and bind-mounted data such as ./data.",
                    deleteFolder && folderProblem == null, folderProblem == null,
                ) { deleteFolder = it }
            }
            Column {
                SectionLabel("Command, run as $user")
                // The folder step makes the command long: the first lines show by default so the name field and the button stay in view.
                var fullCommand by remember { mutableStateOf(false) }
                Text(
                    command, fontFamily = MonoFamily, fontSize = 13.sp, lineHeight = 20.sp, color = c.textPrimary,
                    maxLines = if (fullCommand) Int.MAX_VALUE else 4, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 6.dp).fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(c.background)
                        .border(1.dp, c.border, RoundedCornerShape(12.dp)).padding(horizontal = 16.dp, vertical = 12.dp),
                )
                if (command.count { it == '\n' } > 0 || command.length > 180) {
                    androidx.compose.material3.TextButton({ fullCommand = !fullCommand }) { Text(if (fullCommand) "Show less" else "Show full command", color = c.accent) }
                }
            }
            if (removal.losesData) {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row {
                        Text("Type ", color = c.textSecondary, fontSize = 13.sp)
                        Text(stack.name, color = c.textPrimary, fontSize = 13.sp, fontFamily = MonoFamily)
                        Text(" to confirm", color = c.textSecondary, fontSize = 13.sp)
                    }
                    Field("", typed, stack.name, mono = true) { typed = it }
                    if (typed.isNotEmpty() && typed != stack.name) Text("Name does not match yet", color = c.danger, fontSize = 12.sp)
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(top = 4.dp)) {
                SecondaryButton("Cancel", onCancel, Modifier.weight(1f))
                Button(
                    { onRun(removal) }, Modifier.weight(1f).height(48.dp), enabled = confirmed && command.isNotEmpty(), shape = RoundedCornerShape(24.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = c.danger, contentColor = Color.White, disabledContainerColor = c.selection, disabledContentColor = c.textMuted),
                ) { Text("Delete stack", fontWeight = FontWeight.SemiBold) }
            }
        }
    }
}

/**
 * Deleting a standalone container (started with `docker run`): what is removed and what is kept, an opt-in for its anonymous
 * volumes, the exact command, and always the name typed in, because nothing on the server can create the container again (its
 * settings were only in the original command line). Mirrors the Mac's DeleteContainerSheet.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DeleteContainerSheet(stack: DockerStack, user: String, onCancel: () -> Unit, onRun: (volumes: Boolean) -> Unit) {
    val c = Rackoon.colors
    var removeVolumes by remember { mutableStateOf(false) }
    var typed by remember { mutableStateOf("") }
    val command = StandaloneAction.Remove(removeVolumes).command(stack).orEmpty()

    ModalBottomSheet(
        onDismissRequest = onCancel, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = c.sidebar, scrimColor = Color.Black.copy(alpha = 0.6f),
    ) {
        Column(Modifier.imePadding().padding(horizontal = 20.dp).verticalScroll(rememberScrollState()).padding(bottom = 16.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Column {
                Text("Delete ${stack.name}?", fontSize = 22.sp, fontWeight = FontWeight.Medium, color = c.textPrimary)
                Text(
                    "Stops and removes the container. It was started with docker run, not Docker Compose, so it can't be created again from here: " +
                        "that needs its original docker run command. Its image, named volumes and bind-mounted folders are kept.",
                    color = c.textSecondary, lineHeight = 21.sp, modifier = Modifier.padding(top = 4.dp),
                )
            }
            Option("Also delete its anonymous volumes", "Volumes Docker made for it without a name are lost for good. Named volumes are kept.", removeVolumes, true) { removeVolumes = it }
            Column {
                SectionLabel("Command, run as $user")
                Text(
                    command, fontFamily = MonoFamily, fontSize = 13.sp, lineHeight = 20.sp, color = c.textPrimary,
                    modifier = Modifier.padding(top = 6.dp).fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(c.background)
                        .border(1.dp, c.border, RoundedCornerShape(12.dp)).padding(horizontal = 16.dp, vertical = 12.dp),
                )
            }
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row {
                    Text("Type ", color = c.textSecondary, fontSize = 13.sp)
                    Text(stack.name, color = c.textPrimary, fontSize = 13.sp, fontFamily = MonoFamily)
                    Text(" to confirm", color = c.textSecondary, fontSize = 13.sp)
                }
                Field("", typed, stack.name, mono = true) { typed = it }
                if (typed.isNotEmpty() && typed != stack.name) Text("Name does not match yet", color = c.danger, fontSize = 12.sp)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(top = 4.dp)) {
                SecondaryButton("Cancel", onCancel, Modifier.weight(1f))
                Button(
                    { onRun(removeVolumes) }, Modifier.weight(1f).height(48.dp), enabled = typed == stack.name && command.isNotEmpty(), shape = RoundedCornerShape(24.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = c.danger, contentColor = Color.White, disabledContainerColor = c.selection, disabledContentColor = c.textMuted),
                ) { Text("Delete container", fontWeight = FontWeight.SemiBold) }
            }
        }
    }
}

@Composable
private fun Option(title: String, detail: String, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    val c = Rackoon.colors
    Row(Modifier.fillMaxWidth().clickable(enabled = enabled) { onChange(!checked) }.padding(vertical = 4.dp), verticalAlignment = Alignment.Top) {
        Checkbox(
            checked, { onChange(it) }, enabled = enabled,
            colors = CheckboxDefaults.colors(checkedColor = c.danger, uncheckedColor = c.textMuted, checkmarkColor = Color.White),
        )
        Column(Modifier.padding(top = 10.dp)) {
            Text(title, color = if (enabled) c.textPrimary else c.textMuted)
            Text(detail, fontSize = 12.sp, color = c.textMuted, lineHeight = 17.sp)
        }
    }
}
