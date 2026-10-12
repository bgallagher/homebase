package com.bgallagher.rackoon.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** One file's draft: what the server had, what the user has typed, and the checks of exactly that text. */
data class Draft(
    /** What the server had when the file was opened. Null until loaded. */
    val original: RemoteFileState? = null,
    val text: String = "",
    val loading: Boolean = false,
    val loadError: String? = null,
    val validation: ValidationResult? = null,
    /** The text [validation] belongs to, so a result for older text is never shown as current. */
    val validatedText: String? = null,
    val checkError: String? = null,
    /** Instant local checks (`.env` syntax). */
    val local: List<ComposeIssue> = emptyList(),
    val checking: Boolean = false,
) {
    val originalText: String get() = original?.content ?: ""
    val isDirty: Boolean get() = original != null && !loading && text != originalText
    val changeCount: Int get() = LineDiff.changeCount(originalText, text)
    val changedLines: Set<Int> get() = LineDiff.changedLineNumbers(originalText, text)

    /** Lines to mark in the editor: the local and server errors that belong to this exact text. */
    val errorLines: Set<Int>
        get() {
            if (!isDirty) return emptySet()
            val server = if (validatedText == text) validation?.errors.orEmpty() else emptyList()
            return (local + server).filter { it.severity == ComposeIssue.Severity.ERROR }.mapNotNull { it.line }.toSet()
        }

    /** Saving needs the current text to have passed the server check, and nothing to have changed after it. */
    val passedCheck: Boolean get() = local.isEmpty() && validation != null && validatedText == text && validation.isValid
}

sealed class EditorNotice {
    data class Saved(val file: String, val redeployed: Boolean) : EditorNotice()
    data class ChangedOnServer(val file: EditableFile) : EditorNotice()
    data class Failed(val message: String) : EditorNotice()
}

data class EditorState(
    val drafts: Map<EditableFile, Draft> = emptyMap(),
    val saving: Boolean = false,
    val notice: EditorNotice? = null,
)

/**
 * The compose/.env editor for one stack: the files opened so far (each with the user's draft), the server-side checks of those
 * drafts, and saving. Reads and checks change nothing on the server; a save is a MUTATE intent that the caller must have confirmed.
 * Mirrors `StackEditorModel` on the Mac, but lives in core so the rules (stale results, the conflict path, save gating) are tested.
 */
class StackEditor(
    private val session: StackFileSession,
    private val stack: DockerStack,
    private val serverName: String,
    private val scope: CoroutineScope,
    private val isReadOnly: () -> Boolean,
    private val checkDelayMillis: Long = 600,
) {
    private val _state = MutableStateFlow(EditorState())
    val state: StateFlow<EditorState> = _state.asStateFlow()

    val files: List<EditableFile> get() = session.files

    private val checks = HashMap<EditableFile, Job>()
    private val generations = HashMap<EditableFile, Int>()

    private fun draft(file: EditableFile): Draft = _state.value.drafts[file] ?: Draft()
    private fun update(file: EditableFile, change: (Draft) -> Draft) { _state.update { it.copy(drafts = it.drafts + (file to change(it.drafts[file] ?: Draft()))) } }

    // MARK: reading

    fun open(file: EditableFile) {
        val d = draft(file)
        if (d.original == null && !d.loading) load(file)
    }

    private fun load(file: EditableFile) {
        update(file) { it.copy(loading = true, loadError = null) }
        scope.launch {
            try {
                val read = session.read(file)
                update(file) {
                    it.copy(
                        original = read, text = read.content ?: "", loading = false,
                        loadError = if (read == RemoteFileState.TooLarge) StackFileError.TooLarge.message else null,
                        validation = null, validatedText = null, checkError = null, local = emptyList(), checking = false,
                    )
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                update(file) { it.copy(loading = false, loadError = e.message ?: e.toString()) }
            }
        }
    }

    /** Throws away the draft and re-reads the file (after a conflict, or on request). */
    fun reload(file: EditableFile) {
        checks[file]?.cancel()
        _state.update { it.copy(notice = null) }
        update(file) { it.copy(original = null, checking = false) }
        load(file)
    }

    // MARK: editing

    fun setText(file: EditableFile, text: String) {
        val d = draft(file)
        if (d.original == null || d.text == text) return
        update(file) { it.copy(text = text, local = if (file.isEnv) EnvSyntax.check(text) else emptyList()) }
        _state.update { it.copy(notice = null) }
        scheduleCheck(file)
    }

    fun revert(file: EditableFile) { draft(file).original?.let { setText(file, it.content ?: "") } }

    fun isDirty(file: EditableFile): Boolean = draft(file).isDirty
    val hasUnsavedChanges: Boolean get() = files.any { isDirty(it) }

    fun dismissNotice() { _state.update { it.copy(notice = null) } }

    // MARK: checking

    private fun scheduleCheck(file: EditableFile) {
        checks[file]?.cancel()
        val generation = (generations[file] ?: 0) + 1
        generations[file] = generation
        val d = draft(file)
        // Nothing to check when it matches the server, and a syntax error found locally needs no round trip.
        if (!d.isDirty || d.local.isNotEmpty()) {
            update(file) { it.copy(validation = null, validatedText = null, checkError = null, checking = false) }
            return
        }
        update(file) { it.copy(checking = true) }
        val text = d.text
        checks[file] = scope.launch {
            delay(checkDelayMillis)   // wait for a pause in typing
            var outcome: ValidationResult? = null
            var failure: String? = null
            try {
                outcome = session.validate(file, text)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                failure = e.message ?: e.toString()
            }
            // Only the newest check for this file may report.
            if (generations[file] != generation) return@launch
            update(file) { it.copy(validation = outcome, validatedText = if (outcome == null) null else text, checkError = failure, checking = false) }
        }
    }

    /** The checklist under the editor (YAML syntax, schema, docker compose config; or .env syntax and the compose check). */
    fun rows(file: EditableFile): List<EditorCheckRow> = rows(file, _state.value)

    fun rows(file: EditableFile, state: EditorState): List<EditorCheckRow> {
        val d = state.drafts[file] ?: return emptyList()
        if (d.original == null || !d.isDirty) return emptyList()
        return EditorChecks.rows(file.isEnv, serverName, d.local, d.checkError, d.validation, d.validatedText, d.text)
    }

    // MARK: saving

    fun canSave(file: EditableFile, state: EditorState = _state.value): Boolean {
        val d = state.drafts[file] ?: return false
        return d.isDirty && !state.saving && !isReadOnly() && d.passedCheck
    }

    fun canRedeploy(file: EditableFile, state: EditorState = _state.value): Boolean = canSave(file, state) && ComposeAction.UP.command(stack) != null

    /** Why Save is off, or null when it can go ahead. */
    fun saveBlockedReason(file: EditableFile, state: EditorState = _state.value): String? {
        val d = state.drafts[file] ?: return "Not loaded yet"
        return when {
            isReadOnly() -> "Read-only mode is on"
            state.saving -> "Saving…"
            !d.isDirty -> "No changes to save"
            d.local.isNotEmpty() -> "Fix the syntax error first"
            d.checking || d.validatedText != d.text -> d.checkError ?: "Waiting for the check on $serverName"
            d.validation?.isValid == false -> "Fix the errors above first"
            else -> null
        }
    }

    /** The edit to confirm for a save (what was opened, and what it should become), or null when it can't be saved now. */
    fun editFor(file: EditableFile): FileEdit? {
        if (!canSave(file)) return null
        val d = draft(file)
        return FileEdit(file, d.original?.content, d.original?.sha256, d.text)
    }

    fun intent(edit: FileEdit): Intent? = session.intent(edit)

    /** Saves a confirmed edit. [onSaved] runs after a successful save (the redeploy). */
    fun save(edit: FileEdit, redeploy: Boolean, onSaved: () -> Unit = {}) {
        if (_state.value.saving) return
        _state.update { it.copy(saving = true, notice = null) }
        scope.launch {
            try {
                val confirmation = session.confirm(edit)
                when (val outcome = session.save(edit, confirmation)) {
                    is SaveOutcome.Saved -> {
                        update(edit.file) { d ->
                            val old = (d.original as? RemoteFileState.File)?.file
                            d.copy(
                                original = RemoteFileState.File(RemoteFile(edit.content, outcome.sha256, old?.mode ?: "600", old?.owner ?: "", System.currentTimeMillis() / 1000)),
                                validation = null, validatedText = null, checkError = null,
                            )
                        }
                        _state.update { it.copy(notice = EditorNotice.Saved(edit.file.fileName, redeploy)) }
                        onSaved()
                    }
                    SaveOutcome.ChangedOnServer -> _state.update { it.copy(notice = EditorNotice.ChangedOnServer(edit.file)) }
                    is SaveOutcome.Invalid -> update(edit.file) { it.copy(validation = ValidationResult(outcome.issues), validatedText = edit.content) }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.update { it.copy(notice = EditorNotice.Failed(e.message ?: e.toString())) }
            } finally {
                _state.update { it.copy(saving = false) }
            }
        }
    }

    fun close() { checks.values.forEach { it.cancel() }; checks.clear() }
}
