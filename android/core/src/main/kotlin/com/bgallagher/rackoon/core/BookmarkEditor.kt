package com.bgallagher.rackoon.core

/** One bookmark found on a running container, with where it lives. */
data class BookmarkItem(val stack: DockerStack, val container: DockerContainer, val bookmark: Bookmark) {
    val id: String get() = container.id
    val service: String get() = container.service ?: container.name

    /** What the list shows: the bookmark's name, or the service's. */
    val title: String get() = bookmark.title(service)
}

/** Stacks a bookmark can be added to: compose stacks with at least one container and compose files we can edit. */
val DockerSnapshot.bookmarkableStacks: List<DockerStack>
    get() = stacks.filter { !it.isStandalone && it.containers.isNotEmpty() && StackFiles.editable(it) != null }

val DockerSnapshot.bookmarkItems: List<BookmarkItem>
    get() = stacks.flatMap { stack -> stack.containers.mapNotNull { c -> c.bookmark?.let { BookmarkItem(stack, c, it) } } }

val DockerSnapshot.bookmarkGroups: List<String>
    get() = bookmarkItems.mapNotNull { it.bookmark.group }.toSet().sortedWith(String.CASE_INSENSITIVE_ORDER)

/** The compose services of a stack that have a container, sorted. */
val DockerStack.serviceNames: List<String> get() = containers.mapNotNull { it.service }.toSet().sorted()

/** What a bookmark edit found. */
sealed class BookmarkPlan {
    /** The labels are ready to be written: show the diff, then save [edit]. */
    class Ready(val edit: FileEdit) : BookmarkPlan()

    /** Nothing to do, or it can't be done: [text] says why, in words for the user. */
    class Notice(val text: String) : BookmarkPlan()
}

/**
 * Reads the compose file that defines a service, edits its Homepage labels and returns the change for the user to confirm.
 * Nothing is written here. Mirrors `BookmarkModel.prepare` on the Mac.
 */
object BookmarkEditor {
    suspend fun plan(
        session: StackFileSession, stack: DockerStack, service: String, changes: List<LabelChange>, removing: Boolean, serverName: String,
    ): BookmarkPlan {
        class Found(val file: EditableFile, val remote: RemoteFile, val text: String)
        var found: Found? = null
        val unreadable = ArrayList<String>()
        // The first compose file that defines the service (an override file may be the one that does).
        for (file in session.files.filter { !it.isEnv }) {
            when (val state = session.read(file)) {
                is RemoteFileState.File -> {
                    if (!ComposeLabels.definesService(service, state.file.content)) continue
                    found = try {
                        Found(file, state.file, ComposeLabels.setting(changes, service, state.file.content))
                    } catch (e: ComposeLabelsError) {
                        return BookmarkPlan.Notice(e.message ?: "That file can't be edited automatically.")
                    }
                }
                RemoteFileState.Missing -> unreadable += "${file.fileName} is missing on $serverName"
                RemoteFileState.TooLarge -> unreadable += "${file.fileName} is too large to edit here"
            }
            if (found != null) break
        }
        val f = found ?: return BookmarkPlan.Notice(
            if (unreadable.isEmpty()) "No compose file of ${stack.name} defines a service called $service."
            else "Couldn't read the stack's compose file: " + unreadable.joinToString("; ") + ".",
        )
        if (f.text == f.remote.content) {
            return BookmarkPlan.Notice(if (removing) "$service has no bookmark labels to remove." else "Nothing would change in ${f.file.fileName}.")
        }
        return BookmarkPlan.Ready(FileEdit(f.file, f.remote.content, f.remote.sha256, f.text))
    }
}
