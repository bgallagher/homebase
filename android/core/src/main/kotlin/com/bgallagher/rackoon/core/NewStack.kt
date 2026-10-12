package com.bgallagher.rackoon.core

import java.util.Base64

/** A compose stack that does not exist on the server yet: where it goes and what its files contain. */
data class NewStackPlan(
    val name: String = "",
    /** The folder that will hold the stack's own folder (e.g. `/opt/stacks`). */
    val parentDirectory: String,
    val compose: String = STARTER_COMPOSE,
    /** Contents of `.env`; an empty string means no `.env` file is created. */
    val env: String = "",
) {
    /** Why the name can't be used, or null. It becomes the compose project name and the folder name. */
    val nameProblem: String?
        get() = when {
            name.isEmpty() -> "Enter a name"
            !DockerSession.isComposeProjectName(name) -> "Use lowercase letters, digits, - and _, starting with a letter or digit"
            else -> null
        }

    /** Why the folder can't be used, or null. */
    val folderProblem: String?
        get() {
            val p = normalizedParent
            if (!p.startsWith("/")) return "Enter an absolute path, such as /opt/stacks"
            if (p.split('/').contains("..")) return "The path can't contain .."
            if (ShellQuote.quotePath(p) == null) return "That path can't be used"
            return null
        }

    internal val normalizedParent: String get() = parentDirectory.trim { it == ' ' || it == '\t' }.let { var p = it; while (p.length > 1 && p.endsWith("/")) p = p.dropLast(1); p }

    val isValid: Boolean get() = nameProblem == null && folderProblem == null

    /** `<parent>/<name>`, or null while the name or folder is not usable. */
    val directory: String? get() = if (!isValid) null else if (normalizedParent == "/") "/$name" else "$normalizedParent/$name"

    val composePath: String? get() = directory?.let { "$it/$COMPOSE_FILE_NAME" }
    val hasEnv: Boolean get() = env.isNotEmpty()

    /** The stack as the rest of the app sees it once created, with no containers yet, so the normal compose actions (`up -d`) run on it through the same validation. */
    val stack: DockerStack?
        get() {
            val dir = directory ?: return null
            val path = composePath ?: return null
            return DockerStack(name, dir, path, listOf(path), emptyList(), false)
        }

    companion object {
        const val COMPOSE_FILE_NAME = "compose.yaml"
        const val STARTER_COMPOSE = "services:\n  app:\n    image: nginx:alpine\n    restart: unless-stopped\n    ports:\n      - \"8080:80\"\n"
    }
}

object NewStackDefaults {
    /**
     * Where new stacks should go, learned from the server: the most common parent folder of the existing stacks' working
     * directories. With none, `/opt/stacks` (what Dockge and most guides use) for root, or a `stacks` folder in the user's home so no sudo is needed.
     */
    fun parentDirectory(stacks: List<DockerStack>, user: String?): String {
        val counts = HashMap<String, Int>()
        for (stack in stacks) {
            if (stack.isStandalone) continue
            val dir = stack.workingDir?.takeIf { it.startsWith("/") } ?: continue
            val parent = dir.substringBeforeLast('/', "").ifEmpty { "/" }
            if (parent != "/") counts[parent] = (counts[parent] ?: 0) + 1
        }
        // Ties go to the shorter, then alphabetically first path, so the answer never flips between polls.
        counts.entries.sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key.length }.thenBy { it.key }).firstOrNull()?.let { return it.key }
        if (!user.isNullOrEmpty() && user != "root") return "/home/$user/stacks"
        return "/opt/stacks"
    }
}

/**
 * Commands for creating a stack (spec `stack_new_check`, `stack_create` and their `.env` steps). A check runs in a scratch folder
 * and never touches the stack's real folder. Creating makes the folder (refusing if the name is taken), writes the files, lets the
 * server's `docker compose config` check them in place, and removes everything it made if that fails.
 */
object NewStackCommands {
    fun check(plan: NewStackPlan): String? {
        if (plan.nameProblem != null) return null
        val parts = common(plan) ?: return null
        val env = parts.envB64?.let { Template.fill(SpecCommands.script("stack_new_check_env"), mapOf("envb64" to it)) } ?: ""
        return Template.fill(SpecCommands.script("stack_new_check"), mapOf("b64" to parts.b64, "project" to plan.name, "env" to env))
    }

    fun create(plan: NewStackPlan): String? {
        val dir = plan.directory?.let { ShellQuote.quotePath(it) } ?: return null
        val parent = ShellQuote.quotePath(plan.normalizedParent) ?: return null
        val parts = common(plan) ?: return null
        val env = parts.envB64?.let { Template.fill(SpecCommands.script("stack_create_env"), mapOf("envb64" to it)) } ?: ""
        return Template.fill(SpecCommands.script("stack_create"), mapOf("dir" to dir, "parent" to parent, "b64" to parts.b64, "project" to plan.name, "env" to env))
    }

    private class Parts(val b64: String, val envB64: String?)

    private fun common(plan: NewStackPlan): Parts? {
        if (plan.compose.toByteArray().size > StackFiles.MAX_BYTES || plan.env.toByteArray().size > StackFiles.MAX_BYTES) return null
        // An empty file encodes to an empty string, which `quote` refuses; it is just `''` here.
        val b64 = if (plan.compose.isEmpty()) "''" else ShellQuote.quote(Base64.getEncoder().encodeToString(plan.compose.toByteArray())) ?: return null
        if (plan.env.isEmpty()) return Parts(b64, null)
        val envB64 = ShellQuote.quote(Base64.getEncoder().encodeToString(plan.env.toByteArray())) ?: return null
        return Parts(b64, envB64)
    }
}

sealed class NewStackOutcome {
    object Created : NewStackOutcome()

    /** Something already exists at `<parent>/<name>`. Nothing was written. */
    object Exists : NewStackOutcome()

    /** The server's compose check refused the files. Everything that had been made was removed. */
    data class Invalid(val issues: List<ComposeIssue>) : NewStackOutcome()
}

/** Compose names the file by its full path (the scratch folder, or the new stack's folder). The editor only has `compose.yaml` and `.env`, so show those. */
fun ComposeIssue.simplifyingScratchPaths(): ComposeIssue =
    copy(message = message.replace(Regex("""[^\s:"']*/(compose\.yaml|\.env)"""), "$1"))

/** Checks and creates a new stack's folder and files. A check changes nothing; creating is a MUTATE intent. */
class NewStackSession(private val transport: SSHTransport, private val policy: ActionPolicy = ActionPolicy()) {
    /** Asks the server whether the files would work. Throws if the check itself could not run. */
    suspend fun check(plan: NewStackPlan): ValidationResult {
        if (plan.compose.toByteArray().size > StackFiles.MAX_BYTES || plan.env.toByteArray().size > StackFiles.MAX_BYTES) throw StackFileError.TooLarge
        val command = NewStackCommands.check(plan) ?: throw PolicyError.InvalidTarget
        val result = transport.run(command, 60_000)
        if (result.exitCode == 7 || result.stdout.contains("##cannot-write")) throw StackFileError.CannotWrite
        val output = listOf(result.stdout, result.stderr).joinToString("\n")
        val issues = ComposeIssueParser.parse(output).map { it.simplifyingScratchPaths() }
        if (result.exitCode != 0 && issues.none { it.severity == ComposeIssue.Severity.ERROR }) {
            val detail = output.trim()
            return ValidationResult(issues + ComposeIssue(ComposeIssue.Severity.ERROR, null, detail.ifEmpty { "docker compose config failed (exit ${result.exitCode})" }))
        }
        return ValidationResult(issues)
    }

    /** The intent for creating `plan`, with a readable summary as its preview (the command carries the files encoded). */
    fun intent(plan: NewStackPlan): Intent? {
        val command = NewStackCommands.create(plan) ?: return null
        val directory = plan.directory ?: return null
        val lines = arrayListOf("Create folder $directory", "+ ${NewStackPlan.COMPOSE_FILE_NAME}")
        if (plan.hasEnv) lines += "+ .env (readable only by its owner)"
        val preview = lines.joinToString("\n") + "\n\n" + LineDiff.preview("", plan.compose)
        return Intent("Create stack ${plan.name}", command, Risk.MUTATE, preview)
    }

    fun confirm(plan: NewStackPlan): Confirmation = policy.confirm(intent(plan) ?: throw PolicyError.InvalidTarget)

    suspend fun create(plan: NewStackPlan, confirmation: Confirmation?): NewStackOutcome {
        val intent = intent(plan) ?: throw if (plan.compose.toByteArray().size > StackFiles.MAX_BYTES) StackFileError.TooLarge else PolicyError.InvalidTarget
        policy.authorize(intent, confirmation)
        val result = transport.run(intent.command, 90_000)
        val output = listOf(result.stdout, result.stderr).joinToString("\n")
        return when (result.exitCode) {
            0 -> {
                if (!result.stdout.contains("##created")) throw StackFileError.Malformed("creating did not confirm")
                NewStackOutcome.Created
            }
            3 -> NewStackOutcome.Exists
            4 -> NewStackOutcome.Invalid(ComposeIssueParser.parse(output).filter { it.severity == ComposeIssue.Severity.ERROR }.map { it.simplifyingScratchPaths() })
            7 -> throw StackFileError.CannotWrite
            else -> throw StackFileError.CommandFailed(result.stderr.trim().ifEmpty { "Creating the stack failed (exit ${result.exitCode})" })
        }
    }
}
