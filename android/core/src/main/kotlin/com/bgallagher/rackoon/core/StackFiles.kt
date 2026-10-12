package com.bgallagher.rackoon.core

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Base64

/** A file the stack editor can open: one of the stack's compose files, or the `.env` beside them. */
sealed class EditableFile {
    abstract val path: String

    /** Absolute path of one of the compose files named by the project's `config_files` label. */
    data class Compose(override val path: String) : EditableFile()

    /** Absolute path of `<working_dir>/.env`. */
    data class Env(override val path: String) : EditableFile()

    val isEnv: Boolean get() = this is Env
    val fileName: String get() = path.substringAfterLast('/')
}

object StackFiles {
    /**
     * Largest file the editor will open or save. The content travels inside one remote command line, and Linux caps a single
     * argument at 128 KiB (base64 adds a third), so stay well under.
     */
    const val MAX_BYTES = 65_536

    /**
     * The files offered for a stack: every compose file in merge order, then `.env`. Null if the stack has no single usable
     * compose layout (the same rule the compose actions use).
     */
    fun editable(stack: DockerStack): List<EditableFile>? {
        val dir = stack.workingDir ?: return null
        if (ComposeAction.UP.command(stack) == null) return null
        val paths = stack.configFiles.ifEmpty { listOfNotNull(stack.configFile) }
        return paths.map { EditableFile.Compose(it) } + EditableFile.Env(envPath(dir))
    }

    internal fun envPath(directory: String): String = if (directory.endsWith("/")) "$directory.env" else "$directory/.env"
}

/** What reading a file on the server found. */
sealed class RemoteFileState {
    object Missing : RemoteFileState()
    object TooLarge : RemoteFileState()
    data class File(val file: RemoteFile) : RemoteFileState()

    val content: String? get() = (this as? File)?.file?.content

    /** The hash to send back when saving, so a change made on the server in between is noticed. Null for no file. */
    val sha256: String? get() = (this as? File)?.file?.sha256
}

data class RemoteFile(
    val content: String,
    val sha256: String,
    /** Octal permissions as `stat` prints them, e.g. "644". */
    val mode: String,
    /** "owner:group". */
    val owner: String,
    val modifiedAt: Long,
)

sealed class StackFileError(message: String) : Exception(message) {
    object NoEditableFiles : StackFileError("This stack has no single compose file to edit.")
    class NotEditable(val path: String) : StackFileError("$path is not one of this stack's files.") {
        override fun equals(other: Any?) = other is NotEditable && other.path == path
        override fun hashCode() = path.hashCode()
    }
    object TooLarge : StackFileError("The file is larger than ${StackFiles.MAX_BYTES / 1024} KB, so it can't be edited here.")
    object NotText : StackFileError("The file is not valid UTF-8 text.")
    object CannotWrite : StackFileError("Rackoon can't write in the stack's folder on the server (permissions).")
    class Malformed(val detail: String) : StackFileError("Unexpected output reading the file: $detail") {
        override fun equals(other: Any?) = other is Malformed && other.detail == detail
        override fun hashCode() = detail.hashCode()
    }
    class CommandFailed(val detail: String) : StackFileError(detail)
}

data class ComposeIssue(val severity: Severity, val line: Int?, val message: String) {
    enum class Severity { ERROR, WARNING }

    /**
     * The server checks a temp copy (`.rackoon-check.XXXXXX` / `.rackoon-save.XXXXXX`) of the edited file, and compose names it
     * in its messages. Show the file the user is editing instead.
     */
    fun naming(file: EditableFile): ComposeIssue =
        copy(message = message.replace(Regex("""[^\s\:"']*\.rackoon-(check|save)\.[A-Za-z0-9]+"""), Regex.escapeReplacement(file.fileName)))
}

data class ValidationResult(val issues: List<ComposeIssue>) {
    val errors: List<ComposeIssue> get() = issues.filter { it.severity == ComposeIssue.Severity.ERROR }
    val warnings: List<ComposeIssue> get() = issues.filter { it.severity == ComposeIssue.Severity.WARNING }
    val isValid: Boolean get() = errors.isEmpty()
}

sealed class SaveOutcome {
    /** Written. Carries the new hash for the next save. */
    data class Saved(val sha256: String) : SaveOutcome()

    /** The file on the server is no longer the one that was opened. */
    object ChangedOnServer : SaveOutcome()

    /** The server's own `docker compose config` rejected it; nothing was written. */
    data class Invalid(val issues: List<ComposeIssue>) : SaveOutcome()
}

/** Parses the `file_read` output (`##missing`, `##toolarge`, or `##meta`/`##sha256`/`##content`). */
object RemoteFileParser {
    fun parse(output: String): RemoteFileState {
        val sections = OverviewParser.splitSections(output)
        if (sections["missing"] != null) return RemoteFileState.Missing
        if (sections["toolarge"] != null) return RemoteFileState.TooLarge
        val meta = sections["meta"]?.firstOrNull()?.split(" ", limit = 3)
        val mtime = meta?.takeIf { it.size == 3 }?.get(0)?.toLongOrNull() ?: throw StackFileError.Malformed("no ##meta")
        val sha = sections["sha256"]?.firstOrNull()?.takeIf { it.length == 64 } ?: throw StackFileError.Malformed("no ##sha256")
        // An empty file has an empty base64 line, which splitSections drops.
        val b64 = sections["content"]?.firstOrNull() ?: ""
        val data = try { Base64.getDecoder().decode(b64) } catch (_: IllegalArgumentException) { throw StackFileError.Malformed("content is not base64") }
        val text = try {
            Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(data)).toString()
        } catch (_: java.nio.charset.CharacterCodingException) {
            throw StackFileError.NotText
        }
        return RemoteFileState.File(RemoteFile(text, sha, meta[1], meta[2], mtime))
    }
}

/**
 * Turns the text `docker compose config` prints into issues. Anything it prints on a failing run is an error; `level=warning`
 * log lines are warnings (they appear on success too, e.g. the obsolete `version` key).
 */
object ComposeIssueParser {
    fun parse(output: String): List<ComposeIssue> {
        val issues = ArrayList<ComposeIssue>()
        for (raw in output.split("\n")) {
            val line = raw.trim { it == ' ' || it == '\t' || it == '\r' }
            if (line.isEmpty() || line.startsWith("##")) continue
            if (line.contains("level=warning")) {
                issues += ComposeIssue(ComposeIssue.Severity.WARNING, null, logMessage(line) ?: line)
                continue
            }
            if (line.contains("level=info") || line.contains("level=debug")) continue
            val (number, text) = split(line)
            issues += ComposeIssue(ComposeIssue.Severity.ERROR, number, text)
        }
        return issues
    }

    /**
     * Line numbers appear as `yaml: line 5: could not find expected ':'`, as an indented `line 3: field x not found`, and
     * (newer compose) as `... go-yaml load error in scanner at L4.C12: mapping values are not allowed ...`.
     */
    private fun split(line: String): Pair<Int?, String> {
        Regex("""\bL(\d+)\.C\d+:\s*""").find(line)?.let { m ->
            val rest = line.substring(m.range.last + 1)
            return m.groupValues[1].toIntOrNull() to rest.ifEmpty { line }
        }
        val m = Regex("""(^|\s)line (\d+):\s*""").find(line) ?: return null to line
        val rest = line.substring(m.range.last + 1).ifEmpty { line }
        return m.groupValues[2].toIntOrNull() to rest
    }

    private fun logMessage(line: String): String? {
        val start = line.indexOf("msg=\"").takeIf { it >= 0 } ?: return null
        val tail = line.substring(start + 5)
        val end = tail.lastIndexOf('"').takeIf { it >= 0 } ?: return null
        return tail.substring(0, end).replace("\\\"", "\"")
    }
}
