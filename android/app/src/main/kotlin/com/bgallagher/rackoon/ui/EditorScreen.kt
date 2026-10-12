package com.bgallagher.rackoon.ui

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.layout.defaultMinSize
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
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
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
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.bgallagher.rackoon.AppViewModel
import com.bgallagher.rackoon.core.EditableFile
import com.bgallagher.rackoon.core.EditorCheckRow
import com.bgallagher.rackoon.core.EditorNotice
import com.bgallagher.rackoon.core.RemoteFileState
import com.bgallagher.rackoon.core.SyntaxHighlighter
import com.bgallagher.rackoon.core.SyntaxKind
import com.bgallagher.rackoon.core.TerminalTheme
import com.bgallagher.rackoon.ui.theme.LocalTerminalTheme
import com.bgallagher.rackoon.ui.theme.Rackoon
import com.bgallagher.rackoon.ui.theme.RackoonIcons

private fun com.bgallagher.rackoon.core.RGB.c() = Color(r, g, b)

/** The stack's compose files and `.env`, opened one at a time: edit, see the server's own checks, save (with the diff), redeploy. */
@Composable
fun EditorScreen(vm: AppViewModel, file: EditableFile, readOnly: Boolean) {
    val c = Rackoon.colors
    val state by vm.editorState.collectAsStateWithLifecycle()
    val confirmDiscard by vm.confirmDiscard.collectAsStateWithLifecycle()
    BackHandler(onBack = vm::closeEditor)
    val draft = state.drafts[file]
    val dirty = draft?.isDirty == true
    val rows = vm.editorRows(file)
    val blocked = vm.editorBlockedReason(file)
    val files = vm.editorFiles()

    Column(Modifier.fillMaxSize().background(c.background).statusBarsPadding().imePadding()) {
        Row(Modifier.height(56.dp).padding(end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            IconTap(RackoonIcons.ChevronLeft, "Back to ${vm.editorStackName() ?: "stack"}", c.textPrimary, vm::closeEditor)
            Column(Modifier.weight(1f)) {
                Text(file.fileName + if (dirty) " •" else "", fontFamily = MonoFamily, fontSize = 16.sp, fontWeight = FontWeight.Medium, color = c.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(vm.editorStackName().orEmpty() + (if (dirty) " · ${draft?.changeCount} line${if (draft?.changeCount == 1) "" else "s"} changed" else ""), fontSize = 12.sp, color = c.textMuted, maxLines = 1)
            }
        }
        if (files.size > 1) {
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                files.forEach { f ->
                    val on = f == file
                    val shape = RoundedCornerShape(16.dp)
                    Text(
                        f.fileName + if (state.drafts[f]?.isDirty == true) " •" else "", fontFamily = MonoFamily, fontSize = 13.sp, color = if (on) c.textPrimary else c.textSecondary,
                        modifier = Modifier.clip(shape).background(if (on) c.selection else Color.Transparent).border(1.dp, if (on) c.textMuted.copy(alpha = 0.5f) else c.border, shape)
                            .clickable { vm.showEditorFile(f) }.padding(horizontal = 12.dp, vertical = 8.dp),
                    )
                }
            }
        }
        if (readOnly) ReadOnlyBanner(onTurnOff = vm::toggleReadOnly)

        when {
            draft == null || draft.loading -> Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = c.accent)
                Text("Reading ${file.fileName}…", color = c.textSecondary)
            }
            draft.loadError != null -> Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(draft.loadError.orEmpty(), color = c.danger, lineHeight = 21.sp)
                SecondaryButton("Try again", { vm.editorReload(file) })
            }
            else -> {
                if (draft.original == RemoteFileState.Missing) Text("${file.fileName} doesn't exist on the server yet. Saving creates it.", color = c.textMuted, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp))
                Notice(state.notice, file, vm)
                CodeEditor(
                    text = draft.text, onChange = { vm.editorText(file, it) }, env = file.isEnv, readOnly = readOnly,
                    changedLines = draft.changedLines, errorLines = draft.errorLines, theme = LocalTerminalTheme.current,
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                )
                if (rows.isNotEmpty()) Checklist(rows)
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp).navigationBarsPadding(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SecondaryButton("Revert", { vm.editorRevert(file) }, Modifier.weight(1f), enabled = dirty)
                    SecondaryButton("Save", { vm.requestEditorSave(redeploy = false) }, Modifier.weight(1f), enabled = vm.editorCanSave(file))
                    PrimaryButton("Save & redeploy", { vm.requestEditorSave(redeploy = true) }, Modifier.weight(1.4f), enabled = vm.editorCanRedeploy(file))
                }
                if (dirty && blocked != null) Text(blocked, color = c.textMuted, fontSize = 12.sp, modifier = Modifier.padding(start = 20.dp, bottom = 6.dp))
            }
        }
    }
    if (confirmDiscard) {
        AlertDialog(
            onDismissRequest = vm::keepEditing, containerColor = c.sidebar,
            title = { Text("Discard your changes?") },
            text = { Text("You have unsaved changes. Leaving now throws them away.") },
            confirmButton = { TextButton(vm::closeEditorNow) { Text("Discard", color = c.danger) } },
            dismissButton = { TextButton(vm::keepEditing) { Text("Keep editing") } },
        )
    }
}

@Composable
private fun Notice(notice: EditorNotice?, file: EditableFile, vm: AppViewModel) {
    val c = Rackoon.colors
    notice ?: return
    val (color, text) = when (notice) {
        is EditorNotice.Saved -> c.ok to ("Saved ${notice.file}. The previous version is kept as ${notice.file}.rackoon.bak." + if (notice.redeployed) " Updating the stack…" else "")
        is EditorNotice.ChangedOnServer -> c.warn to "${notice.file.fileName} changed on the server after you opened it, so nothing was saved."
        is EditorNotice.Failed -> c.danger to notice.message
    }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp).clip(RoundedCornerShape(12.dp)).background(color.copy(alpha = 0.12f)).padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(text, color = color, fontSize = 13.sp, lineHeight = 19.sp)
        if (notice is EditorNotice.ChangedOnServer) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SecondaryButton("Reload from server", { vm.editorReload(file) })
            SecondaryButton("Keep editing", vm::editorDismissNotice)
        }
    }
}

@Composable
private fun Checklist(rows: List<EditorCheckRow>) {
    val c = Rackoon.colors
    Column(Modifier.fillMaxWidth().heightIn(max = 124.dp).verticalScroll(rememberScrollState()).background(c.sidebar).padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        rows.forEach { row ->
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.width(16.dp), contentAlignment = Alignment.Center) {
                    when (row.state) {
                        EditorCheckRow.State.RUNNING -> CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp, color = c.accent)
                        EditorCheckRow.State.PASS -> Text("✓", color = c.ok, fontWeight = FontWeight.Bold)
                        EditorCheckRow.State.FAIL -> Text("✕", color = c.danger, fontWeight = FontWeight.Bold)
                        EditorCheckRow.State.WARN -> Text("!", color = c.warn, fontWeight = FontWeight.Bold)
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

private const val LINE_SP = 20f

/**
 * A code view: line numbers, syntax colours from the terminal theme, bands behind changed and failing lines, auto-indent, and a
 * row of the keys a phone keyboard hides. No soft wrap, so every text line is exactly one row and the gutter and bands line up.
 */
@Composable
fun CodeEditor(
    text: String, onChange: (String) -> Unit, env: Boolean, readOnly: Boolean, changedLines: Set<Int>, errorLines: Set<Int>,
    theme: TerminalTheme, modifier: Modifier = Modifier,
) {
    val c = Rackoon.colors
    var value by remember { mutableStateOf(TextFieldValue(text)) }
    // The draft changed from outside (Revert, Reload from Server): show it. Typing always updates `value` first, so this only fires then.
    if (value.text != text) value = TextFieldValue(text, TextRange(minOf(value.selection.start, text.length)))
    val density = LocalDensity.current
    val lineHeight = with(density) { LINE_SP.sp.toDp() }
    val lineCount = value.text.count { it == '\n' } + 1
    val bg = theme.backgroundRGB.c()
    val fg = theme.foregroundRGB.c()
    val ansi = theme.ansiRGB.map { it.c() }
    val styles = remember(theme) {
        mapOf(
            SyntaxKind.KEY to SpanStyle(color = ansi[4]), SyntaxKind.STRING to SpanStyle(color = ansi[2]), SyntaxKind.NUMBER to SpanStyle(color = ansi[3]),
            SyntaxKind.KEYWORD to SpanStyle(color = ansi[5]), SyntaxKind.COMMENT to SpanStyle(color = fg.copy(alpha = 0.45f)), SyntaxKind.PUNCTUATION to SpanStyle(color = fg.copy(alpha = 0.6f)),
        )
    }
    val highlight = remember(env, styles) {
        VisualTransformation { annotated ->
            val builder = AnnotatedString.Builder(annotated.text)
            val tokens = if (env) SyntaxHighlighter.env(annotated.text) else SyntaxHighlighter.yaml(annotated.text)
            for (t in tokens) styles[t.kind]?.let { builder.addStyle(it, t.start, minOf(annotated.text.length, t.start + t.length)) }
            TransformedText(builder.toAnnotatedString(), OffsetMapping.Identity)
        }
    }
    val textStyle = TextStyle(color = fg, fontFamily = MonoFamily, fontSize = 13.sp, lineHeight = LINE_SP.sp)

    Column(modifier.background(bg)) {
        Row(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState())) {
            // Line numbers
            Column(Modifier.width(44.dp).background(bg).padding(end = 6.dp)) {
                for (n in 1..lineCount) Text(
                    "$n", fontFamily = MonoFamily, fontSize = 11.sp, color = if (n in errorLines) c.danger else fg.copy(alpha = 0.35f),
                    modifier = Modifier.height(lineHeight).fillMaxWidth(), textAlign = androidx.compose.ui.text.style.TextAlign.End,
                    lineHeight = LINE_SP.sp,
                )
            }
            Box(
                Modifier.weight(1f).horizontalScroll(rememberScrollState()).drawBehind {
                    val h = with(density) { LINE_SP.sp.toPx() }
                    for (n in changedLines) drawRect(Color(0xFF3FB950).copy(alpha = 0.13f), Offset(0f, (n - 1) * h), Size(size.width.coerceAtLeast(2000f), h))
                    for (n in errorLines) drawRect(c.danger.copy(alpha = 0.22f), Offset(0f, (n - 1) * h), Size(size.width.coerceAtLeast(2000f), h))
                },
            ) {
                BasicTextField(
                    value, { new ->
                        val adjusted = autoIndent(value, new)
                        value = adjusted
                        onChange(adjusted.text)
                    },
                    readOnly = readOnly, textStyle = textStyle, cursorBrush = SolidColor(fg), visualTransformation = highlight,
                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Ascii),
                    modifier = Modifier.padding(end = 40.dp).defaultMinSize(minWidth = 300.dp),
                )
            }
        }
        if (!readOnly) Row(Modifier.fillMaxWidth().background(c.sidebar).horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            // Keys that are awkward or missing on a phone keyboard. "Tab" puts in two spaces: YAML forbids real tabs.
            val keys = listOf("Tab" to "  ", ":" to ":", "-" to "- ", "\"" to "\"", "'" to "'", "$" to "$", "{" to "{", "}" to "}", "[" to "[", "]" to "]", "#" to "#", "=" to "=", "/" to "/")
            keys.forEach { (label, insert) ->
                Box(
                    Modifier.height(40.dp).width(if (label == "Tab") 56.dp else 40.dp).clip(RoundedCornerShape(8.dp)).background(c.card).border(1.dp, c.border, RoundedCornerShape(8.dp))
                        .clickable {
                            val sel = value.selection
                            val updated = value.text.replaceRange(sel.min, sel.max, insert)
                            value = TextFieldValue(updated, TextRange(sel.min + insert.length))
                            onChange(updated)
                        },
                    contentAlignment = Alignment.Center,
                ) { Text(label, fontFamily = MonoFamily, fontSize = 14.sp, color = c.textPrimary) }
            }
        }
    }
}

/** After Enter, the new line starts at the indent of the one above (two deeper after a line ending in a colon). */
private fun autoIndent(old: TextFieldValue, new: TextFieldValue): TextFieldValue {
    if (new.text.length != old.text.length + 1) return new
    val at = new.selection.start - 1
    if (at < 0 || new.text.getOrNull(at) != '\n' || !new.selection.collapsed) return new
    val lineStart = new.text.lastIndexOf('\n', at - 1) + 1
    val prev = new.text.substring(lineStart, at)
    val indent = prev.takeWhile { it == ' ' }.length + if (prev.trimEnd().endsWith(":")) 2 else 0
    if (indent == 0) return new
    val pad = " ".repeat(indent)
    return TextFieldValue(new.text.substring(0, at + 1) + pad + new.text.substring(at + 1), TextRange(at + 1 + indent))
}
