package com.bgallagher.rackoon.core

/**
 * One edit of one file: what was opened, and what it should become. Describes the save for the policy and the confirmation
 * dialog (a readable diff, since the command itself carries the content encoded).
 */
data class FileEdit(
    val file: EditableFile,
    /** The file as it was opened (null if it did not exist) and its hash. */
    val original: String?,
    val originalSHA: String?,
    val content: String,
) {
    val changeCount: Int get() = LineDiff.changeCount(original ?: "", content)
}

/** Reads, checks and saves the files of one stack. Reads and checks change nothing; a save is a MUTATE intent. */
class StackFileSession(
    private val transport: SSHTransport,
    private val stack: DockerStack,
    private val policy: ActionPolicy = ActionPolicy(),
) {
    val files: List<EditableFile> get() = StackFiles.editable(stack) ?: emptyList()

    suspend fun read(file: EditableFile): RemoteFileState {
        val command = StackFileCommands.read(file, stack) ?: throw StackFileError.NotEditable(file.path)
        val result = transport.run(command, 20_000)
        if (result.exitCode != 0) throw StackFileError.CommandFailed(detail(result, "Could not read ${file.fileName}"))
        return RemoteFileParser.parse(result.stdout)
    }

    /**
     * Asks the server whether `content` would work as `file`. Throws if the check itself could not run (no write access to the
     * folder, ssh trouble); a file with errors is a normal result.
     */
    suspend fun validate(file: EditableFile, content: String): ValidationResult {
        if (content.toByteArray(Charsets.UTF_8).size > StackFiles.MAX_BYTES) throw StackFileError.TooLarge
        val command = StackFileCommands.validate(file, content, stack) ?: throw StackFileError.NotEditable(file.path)
        val result = transport.run(command, 60_000)
        if (result.exitCode == 7 || result.stdout.contains("##cannot-write")) throw StackFileError.CannotWrite
        val output = listOf(result.stdout, result.stderr).joinToString("\n")
        val issues = ComposeIssueParser.parse(output).map { it.naming(file) }
        // A non-zero exit with nothing parseable (e.g. docker missing) must not read as "valid".
        if (result.exitCode != 0 && issues.none { it.severity == ComposeIssue.Severity.ERROR }) {
            val detail = output.trim()
            return ValidationResult(
                issues + ComposeIssue(ComposeIssue.Severity.ERROR, null, detail.ifEmpty { "docker compose config failed (exit ${result.exitCode})" }),
            )
        }
        return ValidationResult(issues)
    }

    /** The intent for saving `edit`, with a readable diff as its preview. Pass the same edit to [save]. */
    fun intent(edit: FileEdit): Intent? {
        val command = StackFileCommands.write(edit.file, edit.content, edit.originalSHA, stack) ?: return null
        return Intent("Save ${edit.file.fileName} on ${stack.name}", command, Risk.MUTATE, LineDiff.preview(edit.original ?: "", edit.content))
    }

    fun confirm(edit: FileEdit): Confirmation {
        val intent = intent(edit) ?: throw PolicyError.InvalidTarget
        return policy.confirm(intent)
    }

    suspend fun save(edit: FileEdit, confirmation: Confirmation?): SaveOutcome {
        val intent = intent(edit)
            ?: throw if (edit.content.toByteArray(Charsets.UTF_8).size > StackFiles.MAX_BYTES) StackFileError.TooLarge else PolicyError.InvalidTarget
        policy.authorize(intent, confirmation)
        val result = transport.run(intent.command, 90_000)
        val output = listOf(result.stdout, result.stderr).joinToString("\n")
        return when (result.exitCode) {
            0 -> {
                val lines = result.stdout.split("\n").filter { it.isNotEmpty() }
                val marker = lines.indexOf("##saved")
                if (marker < 0 || marker + 1 !in lines.indices || lines[marker + 1].length != 64) throw StackFileError.Malformed("save did not confirm")
                SaveOutcome.Saved(lines[marker + 1])
            }
            3 -> SaveOutcome.ChangedOnServer
            4 -> SaveOutcome.Invalid(ComposeIssueParser.parse(output).filter { it.severity == ComposeIssue.Severity.ERROR }.map { it.naming(edit.file) })
            7 -> throw StackFileError.CannotWrite
            else -> throw StackFileError.CommandFailed(detail(result, "Saving failed (exit ${result.exitCode})"))
        }
    }

    private fun detail(result: CommandResult, fallback: String): String = result.stderr.trim().ifEmpty { fallback }
}
