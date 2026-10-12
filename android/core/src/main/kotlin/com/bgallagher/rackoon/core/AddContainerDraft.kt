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

enum class AddTarget { NEW_STACK, EXISTING }

/** The existing stack's files as read from the server when it was chosen. */
data class ExistingFiles(val compose: RemoteFileState? = null, val env: RemoteFileState? = null, val error: String? = null)

data class AddState(
    val target: AddTarget = AddTarget.NEW_STACK,
    val spec: ContainerSpec = ContainerSpec(),
    val stackName: String = "",
    val folder: String = "/opt/stacks",
    val existingName: String? = null,
    /** New stacks only: the user pastes a whole compose.yaml (and optionally a .env) instead of filling in the form. */
    val paste: Boolean = false,
    val pasteCompose: String = "",
    val pasteEnv: String = "",
    val existing: ExistingFiles? = null,
    val validation: ValidationResult? = null,
    /** What [validation] belongs to, so a result for older text is never shown as current. */
    val validatedKey: String? = null,
    val checkError: String? = null,
    val imageStatus: ImageStatus? = null,
    val listening: Set<Int>? = null,
    val working: Boolean = false,
    val notice: String? = null,
)

/** What a create or save will do, for the confirmation sheet. */
sealed class DeployRequest {
    abstract val stack: DockerStack
    abstract val start: Boolean
    abstract val title: String
    abstract val message: String
    abstract val preview: String

    class NewStack(val plan: NewStackPlan, override val stack: DockerStack, override val start: Boolean, override val title: String, override val message: String, override val preview: String) : DeployRequest()
    class ExistingStack(
        val edits: List<FileEdit>, override val stack: DockerStack, override val start: Boolean, override val title: String, override val message: String, override val preview: String,
    ) : DeployRequest()
}

data class DeployResult(val stack: DockerStack, val isNew: Boolean, val start: Boolean)

/**
 * The Add container page's rules: where the container goes (a new stack, or an existing one), the form or a pasted compose file, the
 * checks that run on the server (compose, image, ports, name), and what the create or save does. Pure of any screen. Mirrors
 * `AddContainerModel` on the Mac, without the two-way text editing (the preview is read-only; a pasted file replaces the form).
 */
class AddContainerDraft(
    private val transport: SSHTransport,
    private val policy: ActionPolicy,
    private val serverName: String,
    private val scope: CoroutineScope,
    folder: String,
    private val stacks: () -> List<DockerStack>,
    private val containers: () -> List<DockerContainer>,
    private val stackBlockedReason: (DockerStack) -> String? = { null },
    private val debounceMillis: Long = 600,
) {
    private val _state = MutableStateFlow(AddState(folder = folder))
    val state: StateFlow<AddState> = _state.asStateFlow()

    private val newSession = NewStackSession(transport, policy)
    private val checker = ContainerChecker(transport)
    private var fileSession: StackFileSession? = null
    private var checkJob: Job? = null
    private var imageJob: Job? = null
    private var portsJob: Job? = null
    private var generation = 0
    private var imageFor: String? = null
    private var portsFor: List<Int>? = null

    private fun change(block: (AddState) -> AddState) { _state.update(block) }

    // MARK: choosing where it goes

    val existingCandidates: List<DockerStack> get() = stacks().filter { !it.isStandalone && StackFiles.editable(it) != null }
    private fun existingStack(s: AddState): DockerStack? = s.existingName?.let { n -> stacks().firstOrNull { it.name == n } }

    fun setTarget(target: AddTarget) { if (_state.value.target != target) { change { it.copy(target = target, notice = null) }; scheduleChecks() } }
    fun setStackName(name: String) { change { it.copy(stackName = name, notice = null) }; scheduleChecks() }
    fun setFolder(folder: String) { change { it.copy(folder = folder, notice = null) }; scheduleChecks() }
    fun setSpec(spec: ContainerSpec) { change { it.copy(spec = spec, notice = null) }; scheduleChecks() }
    fun setPaste(on: Boolean) { change { it.copy(paste = on, notice = null) }; scheduleChecks() }
    fun setPasteCompose(text: String) { change { it.copy(pasteCompose = text, notice = null) }; scheduleChecks() }
    fun setPasteEnv(text: String) { change { it.copy(pasteEnv = text, notice = null) }; scheduleChecks() }

    fun chooseExisting(name: String) {
        val stack = stacks().firstOrNull { it.name == name }?.takeIf { StackFiles.editable(it) != null } ?: return
        change { it.copy(existingName = name, existing = ExistingFiles(), notice = null) }
        val session = StackFileSession(transport, stack, policy).also { fileSession = it }
        scheduleChecks()
        val files = StackFiles.editable(stack) ?: return
        scope.launch {
            val loaded = try {
                ExistingFiles(compose = session.read(files.first()), env = session.read(files.last()))
            } catch (e: CancellationException) { throw e } catch (e: Exception) { ExistingFiles(error = e.message ?: e.toString()) }
            if (_state.value.existingName != name) return@launch
            change { it.copy(existing = loaded) }
            scheduleChecks()
        }
    }

    // MARK: the files

    private fun pastedMode(s: AddState) = s.paste && s.target == AddTarget.NEW_STACK
    private fun originalCompose(s: AddState): String? = s.existing?.compose?.content
    private fun originalEnv(s: AddState): String = s.existing?.env?.content ?: ""
    private fun existingReady(s: AddState) = s.existing != null && s.existing.error == null && originalCompose(s) != null

    private fun envProblemFree(spec: ContainerSpec) = spec.activeEnv.all { ContainerSpec.envProblem(it) == null } && spec.activeEnv.map { it.key }.toSet().size == spec.activeEnv.size

    private fun generatedCompose(s: AddState): String = when (s.target) {
        AddTarget.NEW_STACK ->
            if (s.spec.name.isEmpty() || s.spec.nameProblem != null || s.spec.image.isEmpty() || s.spec.imageProblem != null) "services:\n  # Enter a container name and an image\n"
            else s.spec.composeText
        AddTarget.EXISTING -> {
            val original = originalCompose(s)
            when {
                original == null -> ""
                s.spec.blockingProblem != null -> original
                else -> try { ComposeInsert.adding(s.spec, original) } catch (_: ComposeInsertError) { original }
            }
        }
    }

    private fun generatedEnv(s: AddState): String = when (s.target) {
        AddTarget.NEW_STACK -> if (envProblemFree(s.spec)) s.spec.envText else ""
        AddTarget.EXISTING -> if (envProblemFree(s.spec)) EnvMerge.merge(originalEnv(s), s.spec.activeEnv).text else originalEnv(s)
    }

    fun composeText(s: AddState = _state.value): String = if (pastedMode(s)) s.pasteCompose else generatedCompose(s)
    fun envText(s: AddState = _state.value): String = if (pastedMode(s)) s.pasteEnv else generatedEnv(s)

    private fun key(s: AddState) = listOf(s.target.name, s.stackName, s.existingName.orEmpty(), s.folder, composeText(s), envText(s)).joinToString("\u0000")

    fun plan(s: AddState = _state.value) = NewStackPlan(name = s.stackName, parentDirectory = s.folder, compose = composeText(s), env = envText(s))

    /** Why adding to the existing stack's file is impossible (inline `services:`, a duplicate name), or null. */
    fun insertProblem(s: AddState = _state.value): String? {
        if (s.target != AddTarget.EXISTING || !existingReady(s) || s.spec.blockingProblem != null) return null
        return try { ComposeInsert.adding(s.spec, originalCompose(s)!!); null } catch (e: ComposeInsertError) { e.message }
    }

    /** Lines to mark in the preview of [file] (compose or env). */
    fun changedLines(s: AddState, env: Boolean): Set<Int> {
        val now = if (env) envText(s) else composeText(s)
        return when (s.target) {
            AddTarget.NEW_STACK -> { val n = now.split("\n").size - if (now.endsWith("\n")) 1 else 0; if (n > 0) (1..n).toSet() else emptySet() }
            AddTarget.EXISTING -> LineDiff.changedLineNumbers(if (env) originalEnv(s) else originalCompose(s) ?: "", now)
        }
    }

    // MARK: checks

    private fun composeSkipReason(s: AddState): String? {
        if (!pastedMode(s)) s.spec.blockingProblem?.let { return it }
        return when (s.target) {
            AddTarget.NEW_STACK -> {
                val p = plan(s)
                if (pastedMode(s) && s.pasteCompose.isBlank()) "Paste a compose.yaml"
                else p.nameProblem?.let { if (s.stackName.isEmpty()) "Enter a stack name" else it } ?: p.folderProblem
            }
            AddTarget.EXISTING -> when {
                s.existingName == null -> "Choose a stack"
                s.existing?.error != null -> s.existing.error
                existingReady(s) -> null
                else -> "Reading the stack from $serverName…"
            }
        }
    }

    private fun scheduleChecks() {
        val s = _state.value
        // Image and port lookups only rerun when what they look at changed.
        if (!pastedMode(s) && s.spec.image != imageFor) {
            imageJob?.cancel()
            imageFor = s.spec.image
            change { it.copy(imageStatus = null) }
            val image = s.spec.image
            if (s.spec.imageProblem == null && image.isNotEmpty()) {
                imageJob = scope.launch {
                    delay(debounceMillis)
                    val status = checker.imageStatus(image)
                    if (imageFor == image) change { it.copy(imageStatus = status) }
                }
            }
        }
        val ports = s.spec.activePorts.mapNotNull { it.hostPort }
        if (portsJob == null || ports != portsFor) {
            portsJob?.cancel()
            portsFor = ports
            change { it.copy(listening = null) }
            portsJob = scope.launch {
                val found = checker.listeningPorts()
                if (portsFor == ports) change { it.copy(listening = found ?: emptySet()) }
            }
        }
        checkJob?.cancel()
        val mine = ++generation
        if (composeSkipReason(s) != null || EnvSyntax.check(envText(s)).isNotEmpty()) {
            change { it.copy(validation = null, validatedKey = null, checkError = null) }
            return
        }
        val snapshotKey = key(s)
        val compose = composeText(s)
        val plan = plan(s)
        val stack = existingStack(s)
        val session = fileSession
        val target = s.target
        change { it.copy(validation = if (it.validatedKey == snapshotKey) it.validation else null) }
        checkJob = scope.launch {
            delay(debounceMillis)   // wait for a pause in typing
            var outcome: ValidationResult? = null
            var failure: String? = null
            try {
                when (target) {
                    AddTarget.NEW_STACK -> outcome = newSession.check(plan)
                    AddTarget.EXISTING -> {
                        val file = stack?.let { StackFiles.editable(it)?.firstOrNull() }
                        if (stack == null || session == null || file == null) return@launch
                        val result = session.validate(file, compose)
                        // The new variables are not in the server's .env until we save, so compose warns about them; that is expected.
                        val added = s.spec.activeEnv.map { it.key }.toSet()
                        outcome = ValidationResult(result.issues.filterNot { i -> i.severity == ComposeIssue.Severity.WARNING && added.any { n -> i.message.contains("\"$n\"") } })
                    }
                }
            } catch (e: CancellationException) { throw e } catch (e: Exception) { failure = e.message ?: e.toString() }
            if (generation != mine) return@launch
            change { it.copy(validation = outcome, validatedKey = if (outcome == null) null else snapshotKey, checkError = failure) }
        }
    }

    /** The variables compose says are not set that the `.env` does not define: Add them to the .env with one tap. */
    fun missingVariables(s: AddState = _state.value): List<String> {
        if (s.validatedKey != key(s)) return emptyList()
        val defined = EnvSyntax.names(envText(s)).toSet()
        return s.validation?.unsetVariables.orEmpty().filter { it !in defined }
    }

    /** Appends `NAME=` lines for the unset variables to the pasted .env (new stack, pasted mode). */
    fun addMissingVariables() {
        val s = _state.value
        val missing = missingVariables(s)
        if (missing.isEmpty() || !pastedMode(s)) return
        var text = s.pasteEnv
        if (text.isNotEmpty() && !text.endsWith("\n")) text += "\n"
        setPasteEnv(text + missing.joinToString("\n") { "$it=" } + "\n")
    }

    /** The checklist: compose (one line when all is well), then image, ports, container name. */
    fun rows(s: AddState = _state.value): List<EditorCheckRow> {
        val rows = ArrayList<EditorCheckRow>()
        val skip = composeSkipReason(s)
        val envIssue = EnvSyntax.check(envText(s)).firstOrNull()
        if (skip != null) {
            rows += EditorCheckRow("yaml", EditorCheckRow.State.SKIPPED, "YAML syntax", skip)
        } else if (envIssue != null) {
            rows += EditorCheckRow("env", EditorCheckRow.State.FAIL, ".env syntax", EditorChecks.describe(envIssue))
        } else {
            val k = key(s)
            rows += ContainerChecks.composeRow(EditorChecks.rows(false, serverName, emptyList(), s.checkError, s.validation, if (s.validatedKey == k) k else null, k), serverName)
        }
        insertProblem(s)?.let { rows += EditorCheckRow("insert", EditorCheckRow.State.FAIL, "Add to stack", it) }
        if (pastedMode(s)) {
            rows += EditorCheckRow("services", EditorCheckRow.State.SKIPPED, "Pasted file", "Image, port and name checks cover the form only. The server's compose check above covers the whole file.")
        } else {
            rows += ContainerChecks.imageRow(s.spec, s.imageStatus)
            rows += ContainerChecks.portRows(s.spec, s.listening, containers(), serverName)
            rows += ContainerChecks.nameRow(s.spec, if (s.target == AddTarget.NEW_STACK) s.stackName else s.existingName, containers())
        }
        if (s.target == AddTarget.EXISTING && s.spec.activeEnv.any { EnvMerge.merge(originalEnv(s), listOf(it)).kept.contains(it.key) }) {
            val kept = EnvMerge.merge(originalEnv(s), s.spec.activeEnv).kept.joinToString(", ")
            rows += EditorCheckRow("envkept", EditorCheckRow.State.WARN, "Already in .env", "$kept keeps its current value")
        }
        return rows
    }

    // MARK: writing

    fun newStackNameProblem(s: AddState = _state.value): String? {
        if (s.stackName.isEmpty()) return null
        plan(s).nameProblem?.let { return it }
        return if (stacks().any { it.name == s.stackName }) "A stack named ${s.stackName} already exists" else null
    }

    /** Why Create/Save is off, or null when it can go ahead. */
    fun deployBlockedReason(s: AddState = _state.value): String? {
        if (policy.isReadOnly) return "Read-only mode is on"
        if (s.working) return "Working…"
        when (s.target) {
            AddTarget.NEW_STACK -> {
                if (s.stackName.isEmpty()) return "Enter a stack name"
                newStackNameProblem(s)?.let { return it }
                plan(s).folderProblem?.let { return it }
            }
            AddTarget.EXISTING -> {
                if (s.existingName == null) return "Choose a stack to add the container to"
                s.existing?.error?.let { return it }
                if (!existingReady(s)) return "Reading the stack from $serverName…"
            }
        }
        if (!pastedMode(s)) s.spec.blockingProblem?.let { return it }
        else if (s.pasteCompose.isBlank()) return "Paste a compose.yaml"
        insertProblem(s)?.let { return it }
        EnvSyntax.check(envText(s)).firstOrNull()?.let { return "Fix .env: ${EditorChecks.describe(it)}" }
        val rows = rows(s)
        rows.firstOrNull { it.state == EditorCheckRow.State.FAIL }?.let { return "${it.title}: ${it.detail}" }
        if (rows.any { it.state == EditorCheckRow.State.RUNNING } || s.validatedKey != key(s)) return s.checkError ?: "Waiting for the checks on $serverName"
        val stack = if (s.target == AddTarget.NEW_STACK) plan(s).stack else existingStack(s)
        if (stack != null) stackBlockedReason(stack)?.let { return it }
        return null
    }

    /** What a create or save would do, for the confirmation sheet, or null when it can't go ahead. */
    fun request(start: Boolean): DeployRequest? {
        val s = _state.value
        if (deployBlockedReason(s) != null) return null
        return when (s.target) {
            AddTarget.NEW_STACK -> {
                val plan = plan(s)
                val stack = plan.stack ?: return null
                val intent = newSession.intent(plan) ?: return null
                val dir = plan.directory ?: return null
                DeployRequest.NewStack(
                    plan, stack, start,
                    title = if (start) "Create ${plan.name} and start it?" else "Create ${plan.name}?",
                    message = "Creates $dir on $serverName with the files below. The server checks them first and removes everything it made if that fails." +
                        if (start) " Then the stack is started with docker compose up -d, which pulls any images it needs." else "",
                    preview = intent.preview.orEmpty(),
                )
            }
            AddTarget.EXISTING -> {
                val stack = existingStack(s) ?: return null
                val session = fileSession ?: return null
                val files = StackFiles.editable(stack) ?: return null
                val composeState = (s.existing?.compose as? RemoteFileState.File)?.file ?: return null
                val compose = FileEdit(files.first(), composeState.content, composeState.sha256, composeText(s))
                val envState = (s.existing?.env as? RemoteFileState.File)?.file
                val env = if (envText(s) != originalEnv(s)) FileEdit(files.last(), envState?.content, envState?.sha256, envText(s)) else null
                val composeIntent = session.intent(compose) ?: return null
                var preview = "compose.yaml\n" + composeIntent.preview.orEmpty()
                env?.let { e -> session.intent(e)?.let { preview += "\n\n.env\n" + it.preview.orEmpty() } }
                DeployRequest.ExistingStack(
                    listOfNotNull(env, compose), stack, start,
                    title = if (start) "Add ${s.spec.name} to ${stack.name} and start it?" else "Add ${s.spec.name} to ${stack.name}?",
                    message = "The server checks each file first, and nothing is written if that fails. The previous versions are kept as .rackoon.bak." +
                        if (start) " Then the stack is updated: the new container starts, and any container whose settings changed is recreated." else "",
                    preview = preview,
                )
            }
        }
    }

    /** Runs a confirmed request. [onDone] gets the result on success; failures become a notice on the page. */
    fun perform(request: DeployRequest, onDone: (DeployResult) -> Unit) {
        if (_state.value.working) return
        change { it.copy(working = true, notice = null) }
        scope.launch {
            try {
                when (request) {
                    is DeployRequest.NewStack -> when (val outcome = newSession.create(request.plan, newSession.confirm(request.plan))) {
                        NewStackOutcome.Created -> onDone(DeployResult(request.stack, true, request.start))
                        NewStackOutcome.Exists -> change { it.copy(notice = "${request.stack.workingDir ?: request.plan.name} already exists on $serverName, so nothing was written. Choose another name or folder.") }
                        is NewStackOutcome.Invalid -> change { it.copy(validation = ValidationResult(outcome.issues), validatedKey = key(it), notice = "$serverName refused the files, so nothing was created.") }
                    }
                    is DeployRequest.ExistingStack -> {
                        val session = fileSession ?: return@launch
                        // .env first: if the compose save is then refused, a spare variable is harmless; the other way round would leave a
                        // service that refers to a variable that was never written.
                        for (edit in request.edits) {
                            when (val outcome = session.save(edit, session.confirm(edit))) {
                                is SaveOutcome.Saved -> continue
                                SaveOutcome.ChangedOnServer -> {
                                    change { it.copy(notice = "${edit.file.fileName} changed on $serverName after you opened this page, so it was not saved. Go back and add the container again.") }
                                    return@launch
                                }
                                is SaveOutcome.Invalid -> {
                                    change { it.copy(validation = ValidationResult(outcome.issues), validatedKey = key(it), notice = "$serverName refused ${edit.file.fileName}, so it was not saved.") }
                                    return@launch
                                }
                            }
                        }
                        onDone(DeployResult(request.stack, false, request.start))
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                change { it.copy(notice = e.message ?: e.toString()) }
            } finally {
                change { it.copy(working = false) }
            }
        }
    }

    val isDirty: Boolean
        get() {
            val s = _state.value
            return s.spec.name.isNotEmpty() || s.spec.image.isNotEmpty() || s.stackName.isNotEmpty() || s.pasteCompose.isNotEmpty() || s.pasteEnv.isNotEmpty() ||
                s.spec.activePorts.isNotEmpty() || s.spec.activeVolumes.isNotEmpty() || s.spec.activeEnv.isNotEmpty()
        }

    /** Starts the checks once the page opens (the port lookup runs straight away). */
    fun start() = scheduleChecks()

    fun close() { checkJob?.cancel(); imageJob?.cancel(); portsJob?.cancel() }
}
