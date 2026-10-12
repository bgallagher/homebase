package com.bgallagher.rackoon.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bgallagher.rackoon.ui.theme.Rackoon

/**
 * Something that changes a server, waiting for a yes. Shown by [ConfirmSheet] with the exact command (or, for a file save, the
 * diff, because the command carries the file encoded). Running it is the view-model's job, so a screen can't skip the sheet.
 */
data class PendingAction(
    val title: String,
    val message: String,
    /** Who the command runs as, for the "Command, run as …" label. */
    val user: String,
    /** The command to show; empty when only [preview] applies. */
    val command: String,
    /** A readable diff of what a save changes (lines start with `+`, `-` or a space). */
    val preview: String? = null,
    val confirmLabel: String = "Run Command",
    val destructive: Boolean = false,
    val run: () -> Unit,
)

/** The design's confirmation sheet: what will happen, the exact command, Cancel and Run Command. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConfirmSheet(action: PendingAction, onCancel: () -> Unit, onConfirm: () -> Unit) {
    val c = Rackoon.colors
    ModalBottomSheet(
        onDismissRequest = onCancel, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = c.sidebar, scrimColor = Color.Black.copy(alpha = 0.6f),
    ) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 16.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Column {
                Text(action.title, fontSize = 22.sp, fontWeight = FontWeight.Medium, color = c.textPrimary)
                Text(action.message, color = c.textSecondary, lineHeight = 21.sp, modifier = Modifier.padding(top = 4.dp))
            }
            Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                action.preview?.let { Block("Changes", diffText(it)) }
                if (action.command.isNotEmpty()) Block("Command, run as ${action.user}", AnnotatedString(action.command))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(top = 6.dp)) {
                SecondaryButton("Cancel", onCancel, Modifier.weight(1f))
                PrimaryButton(action.confirmLabel, onConfirm, Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun Block(label: String, text: AnnotatedString) {
    val c = Rackoon.colors
    Column {
        SectionLabel(label)
        Text(
            text, fontFamily = MonoFamily, fontSize = 13.sp, lineHeight = 20.sp, color = c.textPrimary,
            modifier = Modifier.padding(top = 6.dp).fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Color(0xFF101216))
                .border(1.dp, c.border, RoundedCornerShape(12.dp)).padding(horizontal = 16.dp, vertical = 12.dp),
        )
    }
}

/** A `+`/`-` preview with added lines in green and removed lines in red. */
@Composable
private fun diffText(preview: String): AnnotatedString {
    val c = Rackoon.colors
    return buildAnnotatedString {
        preview.split("\n").forEachIndexed { i, line ->
            if (i > 0) append("\n")
            when {
                line.startsWith("+") -> withStyle(SpanStyle(color = c.ok)) { append(line) }
                line.startsWith("-") -> withStyle(SpanStyle(color = c.danger)) { append(line) }
                else -> withStyle(SpanStyle(color = c.textMuted)) { append(line) }
            }
        }
    }
}
