package com.bgallagher.rackoon.core

import java.util.Base64

/**
 * The shell commands for reading, checking and saving a stack's files. The scripts are read from spec/commands.json
 * (`file_read`, `file_validate`, `file_write`).
 *
 * Safety shape of a save: the new content is written to a temp file in the same folder, checked by the server's own
 * `docker compose config` (so the check sees the same relative paths), and only then moved over the original atomically,
 * after confirming the original still has the hash that was opened. The previous file is kept as `<file>.rackoon.bak`, and
 * owner and permissions are carried over.
 */
object StackFileCommands {
    private const val EXPECT_EXISTING = """[ "${'$'}(sha256sum "${'$'}F" | cut -d' ' -f1)" = {sha} ] || { echo '##changed'; exit 3; }"""
    private const val EXPECT_NONE = """[ ! -e "${'$'}F" ] || { echo '##changed'; exit 3; }"""

    /** Reads one file. Null if the file is not one the stack offers. */
    fun read(file: EditableFile, stack: DockerStack): String? {
        if (StackFiles.editable(stack)?.contains(file) != true) return null
        val path = ShellQuote.quotePath(file.path) ?: return null
        return Template.fill(SpecCommands.script("file_read"), mapOf("file" to path))
    }

    /** Checks `content` as the new version of `file` using the server's `docker compose config`, changing nothing. */
    fun validate(file: EditableFile, content: String, stack: DockerStack): String? {
        val parts = common(file, content, stack) ?: return null
        return Template.fill(SpecCommands.script("file_validate"), mapOf("dir" to parts.dir, "b64" to parts.b64, "project" to stack.name, "args" to parts.args))
    }

    /** Saves `content` over `file`. `expectedSHA` is the hash of the version that was opened (null if the file did not exist). */
    fun write(file: EditableFile, content: String, expectedSHA: String?, stack: DockerStack): String? {
        val parts = common(file, content, stack) ?: return null
        val path = ShellQuote.quotePath(file.path) ?: return null
        val expect = if (expectedSHA != null) {
            if (expectedSHA.length != 64 || !expectedSHA.all { it in '0'..'9' || it in 'a'..'f' }) return null
            Template.fill(EXPECT_EXISTING, mapOf("sha" to "'$expectedSHA'"))
        } else {
            EXPECT_NONE
        }
        return Template.fill(
            SpecCommands.script("file_write"),
            mapOf("file" to path, "dir" to parts.dir, "b64" to parts.b64, "project" to stack.name, "args" to parts.args, "expect" to expect),
        )
    }

    private class Parts(val dir: String, val b64: String, val args: String)

    private fun common(file: EditableFile, content: String, stack: DockerStack): Parts? {
        if (StackFiles.editable(stack)?.contains(file) != true) return null
        val bytes = content.toByteArray(Charsets.UTF_8)
        if (bytes.size > StackFiles.MAX_BYTES) return null
        val dir = stack.workingDir?.let { ShellQuote.quotePath(it) } ?: return null
        // An empty file encodes to an empty string, which `quote` refuses; it is just `''` here.
        val b64 = if (content.isEmpty()) "''" else ShellQuote.quote(Base64.getEncoder().encodeToString(bytes)) ?: return null
        val args = composeArguments(file, stack) ?: return null
        return Parts(dir, b64, args)
    }

    /**
     * `-f` for every compose file, with the edited one swapped for the temp file (`"$T"`), or `--env-file "$T"` when `.env` is
     * the file being edited. Everything else is quoted as in the compose actions.
     */
    internal fun composeArguments(file: EditableFile, stack: DockerStack): String? {
        val paths = stack.configFiles.ifEmpty { listOfNotNull(stack.configFile) }
        val temp = "\"${'$'}T\""
        val parts = ArrayList<String>()
        if (file.isEnv) parts += listOf("--env-file", temp)
        for (path in paths) {
            if (file == EditableFile.Compose(path)) {
                parts += listOf("-f", temp)
            } else {
                parts += listOf("-f", ShellQuote.quotePath(path) ?: return null)
            }
        }
        return if (parts.isEmpty()) null else parts.joinToString(" ")
    }
}
