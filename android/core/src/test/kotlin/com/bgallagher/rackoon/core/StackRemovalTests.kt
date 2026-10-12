package com.bgallagher.rackoon.core

import java.io.File
import java.nio.file.Files
import java.nio.file.Path
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class StackRemovalTests {
    private val cleanup = mutableListOf<File>()

    @AfterTest fun tidy() { cleanup.forEach { it.deleteRecursively() }; cleanup.clear() }

    private fun stack(dir: String = "/opt/stacks/media", files: List<String>? = null, standalone: Boolean = false, name: String = "media"): DockerStack {
        val f = files ?: listOf("$dir/compose.yaml")
        val c = DockerContainer(
            id = "abcdef012345", name = "media-web-1", image = "nginx", state = "running", health = "none", status = "Up", ports = emptyList(),
            project = name, service = "web", workingDir = dir, configFile = f.firstOrNull(), configFiles = f,
        )
        return DockerStack(name, dir, f.firstOrNull(), f, listOf(c), standalone)
    }

    @Test fun `commands are exact`() {
        val base = "cd '/opt/stacks/media' && docker compose -p media -f '/opt/stacks/media/compose.yaml' down --remove-orphans"
        assertEquals(base, StackRemoval().command(stack()))
        assertEquals("$base -v", StackRemoval(removeVolumes = true).command(stack()))
        val folder = StackRemoval(deleteFolder = true).command(stack()).orEmpty()
        assertTrue(folder.startsWith("$base && cd / && { [ -f '/opt/stacks/media/compose.yaml' ] || {"), folder)
        assertTrue(folder.contains("[ ! -L '/opt/stacks/media' ] || {"), folder)
        assertTrue(folder.contains("R=\$(readlink -f -- '/opt/stacks/media')"), folder)
        assertTrue(folder.contains("case \"\$(readlink -f -- '/opt/stacks/media/compose.yaml')\" in \"\$R\"/*) true;;"), folder)
        assertTrue(folder.contains("rm -rf -- '/opt/stacks/media' || { [ \"\$(id -u)\" -ne 0 ] && sudo -n rm -rf -- '/opt/stacks/media'; }"), folder)
        assertEquals("Delete stack media and its folder", StackRemoval(removeVolumes = true, deleteFolder = true).intent(stack())?.summary)
        assertEquals(Risk.MUTATE, StackRemoval().intent(stack())?.risk)
    }

    @Test fun `folder deletion is refused for system and home folders`() {
        val bad = listOf(
            "/", "/opt", "/home", "/home/brian", "/root", "/var", "/var/lib", "/var/lib/docker", "/usr/local", "/etc", "/tmp", "/srv",
            "/opt/../etc", "/opt/./x", "/opt//x", "/opt/stacks/", "/data", "/Users/brian", "/mnt/disk", "/media/usb", "/usr/local/bin",
            "/var/lib/docker/volumes", "/etc/stacks/x", "/boot/x", "/snap/x",
        )
        for (dir in bad) {
            val s = stack(dir = dir, files = listOf(if (dir.endsWith("/")) dir + "compose.yaml" else "$dir/compose.yaml"))
            assertNotNull(StackRemoval.folderProblem(s), dir)
            assertNull(StackRemoval(deleteFolder = true).command(s), dir)
        }
        for (dir in listOf("/opt/stacks/media", "/opt/media", "/srv/media", "/home/brian/stacks/media", "/mnt/data/stacks/x", "/data/media", "/Users/brian/stacks")) {
            assertNull(StackRemoval.folderProblem(stack(dir = dir)), dir)
        }
        // A compose file outside the folder, or an unknown folder: no folder deletion, but plain removal is still fine.
        val outside = stack(files = listOf("/opt/stacks/media/compose.yaml", "/etc/other.yaml"))
        assertNotNull(StackRemoval.folderProblem(stack(files = listOf("/opt/stacks/media/../../x/compose.yaml"))), "a .. inside a compose file path")
        assertNotNull(StackRemoval.folderProblem(stack(files = listOf("/opt/stacks/media/./compose.yaml"))))
        assertNotNull(StackRemoval.folderProblem(outside))
        assertNull(StackRemoval(deleteFolder = true).command(outside))
        assertNotNull(StackRemoval(removeVolumes = true).command(outside))
    }

    @Test fun `standalone and unsafe projects are refused`() {
        assertNull(StackRemoval().command(stack(standalone = true)))
        assertNull(StackRemoval().command(stack(name = "media; reboot")))
        assertNull(StackRemoval().command(stack(dir = "relative", files = listOf("relative/compose.yaml"))))
    }

    @Test fun `removal needs confirmation and honours read-only`() {
        val policy = ActionPolicy()
        val session = DockerSession(FakeTransport(), policy = policy)
        session.confirm(StackRemoval(), stack())
        assertFailsWith<PolicyError.InvalidTarget> { session.confirm(StackRemoval(deleteFolder = true), stack(dir = "/opt")) }
        policy.isReadOnly = true
        assertFailsWith<PolicyError.ReadOnly> { session.confirm(StackRemoval(), stack()) }
    }

    // MARK: the real command under /bin/sh with a stub `docker`

    private fun realTemp(): File {
        // Resolved, because the guard compares real paths (macOS keeps temp folders under the /var -> /private/var symlink).
        val root = Files.createTempDirectory("rk-del-").toRealPath().toFile()
        cleanup += root
        return root
    }

    private class Ran(val code: Int, val out: String)

    private fun run(removal: StackRemoval, dir: File, dockerExit: Int): Ran {
        val bin = Files.createTempDirectory("rk-bin-").toRealPath().toFile().also { cleanup += it }
        val stub = File(bin, "docker").apply { writeText("#!/bin/sh\nexit $dockerExit\n"); setExecutable(true) }
        assertTrue(stub.canExecute())
        val command = assertNotNull(removal.command(stack(dir = dir.path)))
        val p = ProcessBuilder("/bin/sh", "-c", command).redirectErrorStream(true).also { it.environment()["PATH"] = "${bin.path}:/usr/bin:/bin" }.start()
        val out = p.inputStream.bufferedReader().readText()
        assertTrue(p.waitFor(60, TimeUnit.SECONDS))
        return Ran(p.exitValue(), out)
    }

    private fun mkdirs(f: File) = f.also { it.mkdirs() }

    @Test fun `the folder is deleted only after down succeeds and only with its compose file`() {
        val root = realTemp()
        fun make(name: String, compose: Boolean): File {
            val d = mkdirs(File(root, "stacks/$name"))
            mkdirs(File(d, "data")); File(d, "data/file").writeText("x")
            if (compose) File(d, "compose.yaml").writeText("services: {}")
            return d
        }
        val ok = make("ok", true)
        assertEquals(0, run(StackRemoval(deleteFolder = true), ok, 0).code)
        assertFalse(ok.exists(), "folder with its data is gone")
        assertTrue(File(root, "stacks").exists(), "the parent is untouched")

        val failing = make("failing", true)
        assertNotEquals(0, run(StackRemoval(deleteFolder = true), failing, 1).code)
        assertTrue(File(failing, "data/file").exists(), "down failed: nothing deleted")

        val noCompose = make("nocompose", false)
        assertNotEquals(0, run(StackRemoval(deleteFolder = true), noCompose, 0).code)
        assertTrue(File(noCompose, "data/file").exists(), "no compose file: folder is not emptied")

        val keep = make("keep", true)
        assertEquals(0, run(StackRemoval(), keep, 0).code)
        assertTrue(File(keep, "compose.yaml").exists(), "plain removal keeps the files")
    }

    @Test fun `a symlink cannot redirect the delete`() {
        val root = realTemp()
        // The stack folder is a symlink to a precious folder: nothing in it may be deleted.
        val precious = mkdirs(File(root, "precious"))
        File(precious, "compose.yaml").writeText("services: {}")
        mkdirs(File(root, "stacks"))
        val link = File(root, "stacks/linked")
        Files.createSymbolicLink(link.toPath(), precious.toPath())
        assertNotEquals(0, run(StackRemoval(deleteFolder = true), link, 0).code)
        assertTrue(File(precious, "compose.yaml").exists())

        // The compose file is a symlink to a file outside the folder: the folder is not deleted either.
        val real = mkdirs(File(root, "stacks/real"))
        mkdirs(File(real, "data"))
        Files.createSymbolicLink(File(real, "compose.yaml").toPath(), File(precious, "compose.yaml").toPath())
        assertNotEquals(0, run(StackRemoval(deleteFolder = true), real, 0).code)
        assertTrue(File(real, "data").exists())
    }

    @Test fun `a symlinked parent folder is fine and guard failures say so`() {
        val root = realTemp()
        // /opt-style layout: <root>/link is a symlink to <root>/real, and the stack is addressed through the link.
        val real = mkdirs(File(root, "real/stacks/app"))
        mkdirs(File(real, "data")); File(real, "compose.yaml").writeText("services: {}")
        Files.createSymbolicLink(File(root, "link").toPath(), File(root, "real").toPath())
        val viaLink = File(root, "link/stacks/app")
        val ok = run(StackRemoval(deleteFolder = true), viaLink, 0)
        assertEquals(0, ok.code, ok.out)
        assertFalse(real.exists(), "deleted through the symlinked parent")
        assertTrue(real.parentFile.exists(), "the parent is untouched")

        // A guard that fails says why instead of exiting silently, and deletes nothing.
        val bare = mkdirs(File(root, "real/stacks/bare"))
        val missing = run(StackRemoval(deleteFolder = true), bare, 0)
        assertEquals(6, missing.code)
        assertTrue(missing.out.contains("its compose file is missing"), missing.out)
        assertTrue(bare.exists())

        // The folder itself being a symlink is reported as that, not as a file problem.
        val target = mkdirs(File(root, "real/stacks/target"))
        File(target, "compose.yaml").writeText("services: {}")
        val linked = File(root, "real/stacks/linked")
        Files.createSymbolicLink(linked.toPath(), target.toPath())
        val symlink = run(StackRemoval(deleteFolder = true), linked, 0)
        assertEquals(6, symlink.code)
        assertTrue(symlink.out.contains("it is a symbolic link"), symlink.out)
        assertTrue(File(target, "compose.yaml").exists())

        // A compose file that really lives elsewhere is reported as that.
        val outside = mkdirs(File(root, "real/stacks/outside"))
        val elsewhere = File(root, "elsewhere.yaml").apply { writeText("services: {}") }
        Files.createSymbolicLink(File(outside, "compose.yaml").toPath(), elsewhere.toPath())
        val notInside = run(StackRemoval(deleteFolder = true), outside, 0)
        assertEquals(6, notInside.code)
        assertTrue(notInside.out.contains("not inside it"), notInside.out)
        assertTrue(elsewhere.exists())
    }
}
