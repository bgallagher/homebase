package com.bgallagher.rackoon.core

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Mirrors ServicesTests.swift. */
class ServicesTests {
    private fun fixture(name: String): ServicesSnapshot = ServicesParser.parse(Spec.out("services", name))

    private fun ServicesSnapshot.service(id: String): DiscoveredService =
        services.firstOrNull { it.id == id } ?: throw AssertionError("no $id in ${services.map { it.id }}")

    @Test fun everyServicesFixtureMatchesItsGoldenFile() {
        val names = Spec.fixtures("services").filterNot { it.startsWith("raw-") }
        assertTrue(names.size >= 4)
        for (name in names) {
            val actual = Json.parseToJsonElement(Spec.json.encodeToString(ServicesParser.parse(Spec.out("services", name))))
            assertJsonEquals(Spec.expected("services", name), actual, "services/$name")
        }
    }

    @Test fun commandComesFromTheSpec() {
        assertEquals(SpecCommands.script("services"), ServicesSession.command)
        assertTrue(ServicesSession.command.startsWith("echo '##uptime'"))
    }

    // Real servers

    @Test fun runnerHostFindsTheSelfHostedServicesAndHidesThePlumbing() {
        val s = fixture("ubuntu-runner-host")
        assertTrue(s.hasSystemd)
        assertFalse(s.isRoot)
        val visible = s.services.filter { it.visibleByDefault }.map { it.id }.toSet()
        for (id in listOf("system/tailscaled.service", "system/wazuh-agent.service", "system/beszel-agent.service", "system/docker.service",
            "system/actions.runner.example-repo.runner1.service", "system/lab-journal.service", "system/lab-netconsole.service")) {
            assertTrue(id in visible, id)
        }
        for (id in listOf("system/dbus.service", "system/cron.service", "system/getty@tty1.service", "system/systemd-journald.service",
            "system/cups.service", "system/containerd.service", "system/ssh.service", "system/user@1000.service")) {
            assertFalse(id in visible, id)
        }
        // One-shots that ran at boot and are done are not services at all.
        assertNull(s.services.firstOrNull { it.unit == "ufw.service" || it.unit == "apparmor.service" || it.unit == "kdump-tools.service" })
        val tailscale = s.service("system/tailscaled.service")
        assertEquals("Tailscale", tailscale.name)
        assertEquals("tailscale", tailscale.product)
        assertEquals(DiscoveredService.Status.RUNNING, tailscale.status)
        assertEquals(true, tailscale.enabledAtBoot)
        assertNotNull(tailscale.activeSeconds)
        assertEquals("GitHub Actions runner", s.service("system/actions.runner.example-repo.runner1.service").name)
        assertEquals(851_849_216L, s.service("system/wazuh-agent.service").memoryBytes)
        // A non-root user sees no process names in ss, so no ports are known here.
        assertTrue(s.services.all { it.ports.isEmpty() })
    }

    @Test fun userUnitsAndHandStartedProcessesWithTheirPorts() {
        val s = fixture("ubuntu-user-units-and-processes")
        val gateway = s.service("user/hermes-gateway.service")
        assertEquals(DiscoveredService.Kind.USER, gateway.kind)
        assertEquals("Hermes Agent gateway", gateway.name)
        assertEquals(1, gateway.restarts)
        assertEquals(listOf(ServicePort("127.0.0.1", 38165)), gateway.ports)
        assertTrue(gateway.visibleByDefault)
        // The user's PipeWire and dbus are plumbing.
        assertFalse(s.service("user/pipewire.service").visibleByDefault)
        assertFalse(s.service("user/dbus.service").visibleByDefault)

        val hermes = s.service("process/hermes")
        assertEquals(DiscoveredService.Kind.PROCESS, hermes.kind)
        assertEquals("Hermes Agent", hermes.name)
        assertEquals(listOf(ServicePort("100.64.0.10", 9119)), hermes.ports)
        assertTrue(hermes.visibleByDefault)

        // `npx paperclipai` and the postgres it started in the same login session are one service.
        val paperclip = s.service("process/paperclipai")
        assertEquals("Paperclip", paperclip.name)
        assertEquals(listOf(3100, 54329), paperclip.ports.map { it.port })
        assertNull(s.services.firstOrNull { it.id == "process/postgres" })
        assertTrue(paperclip.visibleByDefault)
        assertNull(paperclip.unit)
    }

    // Synthetic cases

    @Test fun rootSeesEveryPortAndProblemsAreAlwaysShown() {
        val s = fixture("synthetic-root-failed")
        assertTrue(s.isRoot)
        val backup = s.service("system/backup-sync.service")
        assertEquals(DiscoveredService.Status.FAILED, backup.status)
        assertEquals("exit-code", backup.result)
        assertEquals(5, backup.restarts)
        assertTrue(backup.visibleByDefault)
        assertTrue(backup.isProblem)

        val tunnel = s.service("system/cloudflared.service")
        assertEquals(DiscoveredService.Status.RESTARTING, tunnel.status)
        assertEquals("Cloudflare Tunnel", tunnel.name)
        assertTrue(tunnel.isProblem)

        val beszel = s.service("system/beszel-agent.service")
        assertEquals(DiscoveredService.Status.STOPPED, beszel.status, "enabled but not running")
        assertNull(beszel.activeSeconds)

        val nginx = s.service("system/nginx.service")
        assertEquals(listOf(ServicePort("0.0.0.0", 80), ServicePort("0.0.0.0", 443)), nginx.ports)
        assertEquals("Pi-hole", s.service("system/pihole-FTL.service").name)
        val code = s.service("system/code-server@alice.service")
        assertEquals("code-server", code.name)
        assertEquals(listOf(ServicePort("127.0.0.1", 8080)), code.ports)
        assertEquals(2, code.restarts)
        // ssh holds port 22 on both stacks: one entry, and hidden by default (it is always there).
        val ssh = s.service("system/ssh.service")
        assertEquals(listOf(22), ssh.ports.map { it.port })
        assertFalse(ssh.visibleByDefault)

        // Docker's own ports and a container's process belong to the Docker screen.
        assertNull(s.services.firstOrNull { svc -> svc.ports.any { it.port == 9000 || it.port == 8123 } })
        assertEquals(emptyList(), s.service("system/docker.service").ports)
        // A root-owned process outside any unit and session, unknown: listed, hidden.
        val frps = s.service("process/frps")
        assertFalse(frps.visibleByDefault)
        assertEquals(listOf(7000), frps.ports.map { it.port })
        // Not found, and the one-shot ufw, are not listed.
        assertNull(s.services.firstOrNull { it.unit == "old-thing.service" || it.unit == "ufw.service" })
        assertEquals(86_388.25, s.service("system/tailscaled.service").activeSeconds ?: 0.0, 0.01)
    }

    @Test fun serverWithoutSystemdListsKnownProcesses() {
        val s = fixture("synthetic-no-systemd")
        assertFalse(s.hasSystemd)
        assertTrue(s.service("process/syncthing").visibleByDefault)
        assertEquals("Samba", s.service("process/smbd").name)
        assertTrue(s.service("process/nginx").visibleByDefault)
        assertFalse(s.service("process/sshd").visibleByDefault)
    }

    /** A real Unraid server (root, no systemd): Docker's port helpers are not services, and nginx's master and worker are one service named after the master. */
    @Test fun unraidHidesDockerHelpersAndMergesWorkers() {
        val s = fixture("unraid-no-systemd-root")
        assertTrue(s.isRoot)
        assertFalse(s.hasSystemd)
        assertNull(s.services.firstOrNull { it.name.contains("docker-proxy") })
        val nginx = s.services.filter { it.name == "nginx" }
        assertEquals(1, nginx.size)
        assertTrue(nginx[0].detail.contains("master process"))
        assertEquals(listOf(80, 443), nginx[0].ports.map { it.port })
        assertEquals(setOf("nginx", "Samba", "Tailscale"), s.services.filter { it.visibleByDefault }.map { it.name }.toSet())
        assertEquals(7, s.services.size)
    }

    // Rules

    @Test fun cgroupHomes() {
        assertEquals(ServiceDiscovery.Home.SystemUnit("nginx.service"), ServiceDiscovery.home("/system.slice/nginx.service"))
        assertEquals(ServiceDiscovery.Home.UserUnit("x.service"), ServiceDiscovery.home("/user.slice/user-1000.slice/user@1000.service/app.slice/x.service"))
        assertEquals(
            ServiceDiscovery.Home.Loose("/user.slice/user-1000.slice/session-3.scope"),
            ServiceDiscovery.home("/user.slice/user-1000.slice/session-3.scope"),
        )
        assertEquals(ServiceDiscovery.Home.Container, ServiceDiscovery.home("/system.slice/docker-4f1c.scope"))
        assertEquals(ServiceDiscovery.Home.Container, ServiceDiscovery.home("/kubepods/burstable/pod1/abc"))
        assertEquals(ServiceDiscovery.Home.Loose("/"), ServiceDiscovery.home("/"))
    }

    @Test fun processNames() {
        assertEquals("paperclipai", ServiceDiscovery.processName("node-MainThread", "node /x/.bin/paperclipai onboard --yes"))
        assertEquals("homeassistant", ServiceDiscovery.processName("python3", "python3 -m homeassistant --config /config"))
        assertEquals("serve", ServiceDiscovery.processName("python3.12", "/usr/bin/python3.12 /opt/app/serve.py"))
        assertEquals("python3", ServiceDiscovery.processName("python3", "python3 -I -c import os"))
        assertEquals("hermes", ServiceDiscovery.processName("hermes", "python3 -c ..."))
        assertEquals("java", ServiceDiscovery.processName("java", "java -Xmx1g -jar /opt/mc/server.jar"))
    }

    @Test fun catalogNamesAndPlumbing() {
        assertEquals("code-server", ServiceCatalog.baseName("code-server@alice.service"))
        assertEquals("wpa-supplicant", ServiceCatalog.baseName("wpa_supplicant.service"))
        assertEquals("pi-hole", ServiceCatalog.product("pihole-FTL.service")?.id)
        assertEquals("github-runner", ServiceCatalog.product("actions.runner.org-repo.host.service")?.id)
        assertTrue(ServiceCatalog.isPlumbing("systemd-resolved.service"))
        assertTrue(ServiceCatalog.isPlumbing("wpa_supplicant.service"))
        assertFalse(ServiceCatalog.isPlumbing("tailscaled.service"))
        assertEquals("code-server (alice)", ServiceDiscovery.displayName("code-server@alice.service"))
        // Product ids are unique.
        assertEquals(ServiceCatalog.products.size, ServiceCatalog.products.map { it.id }.toSet().size)
    }

    @Test fun portLinks() {
        assertEquals("100.64.0.10", ServicePort("0.0.0.0", 80).linkHost(preferred = "100.64.0.10"))
        assertEquals("192.168.1.20", ServicePort("*", 80).linkHost(preferred = "192.168.1.20"))
        assertNull(ServicePort("127.0.0.1", 80).linkHost(preferred = "x"))
        assertNull(ServicePort("::1", 80).linkHost(preferred = "x"))
        assertEquals("100.64.0.10", ServicePort("100.64.0.10", 9119).linkHost(preferred = "192.168.1.20"))
        assertEquals("[fd7a::10]", ServicePort("fd7a::10", 80).linkHost(preferred = null))
        assertFalse(ServicePort("0.0.0.0", 22).isLikelyWeb)
        assertTrue(ServicePort("0.0.0.0", 3100).isLikelyWeb)
    }

    @Test fun searchMatches() {
        val nginx = fixture("synthetic-root-failed").service("system/nginx.service")
        assertTrue(nginx.matches("nginx 443"))
        assertTrue(nginx.matches("REVERSE proxy"))
        assertFalse(nginx.matches("nginx 8443"))
    }

    // Showing and hiding

    @Test fun visibilityOverrides() {
        val s = fixture("synthetic-root-failed")
        val ssh = s.service("system/ssh.service")
        val nginx = s.service("system/nginx.service")
        val v = ServiceVisibility()
        assertFalse(v.isVisible(ssh, server = "a"))
        v.set(true, service = ssh.id, server = "a")
        assertTrue(v.isVisible(ssh, server = "a"))
        assertFalse(v.isVisible(ssh, server = "b"))
        assertTrue(v.isChosen(ssh, server = "a"))

        // Everywhere replaces each server's own choice for that service.
        v.set(false, service = nginx.id, server = "a")
        v.set(true, service = ssh.id, server = "a", everywhere = true)
        assertTrue(v.isVisible(ssh, server = "b"))
        assertNull(v.overrides["a|" + ssh.id])
        assertFalse(v.isVisible(nginx, server = "a"))
        assertTrue(v.isVisible(nginx, server = "b"))
        // A server's own choice still wins over the everywhere rule.
        v.set(false, service = ssh.id, server = "c")
        assertFalse(v.isVisible(ssh, server = "c"))

        assertTrue(v.forget("a"))
        assertTrue(v.isVisible(nginx, server = "a"))
        assertFalse(v.forget("a"))
        v.set(null, service = ssh.id, server = "*", everywhere = true)
        assertFalse(v.isVisible(ssh, server = "b"))
    }

    // Actions

    @Test fun actionCommands() {
        val s = fixture("ubuntu-user-units-and-processes")
        val tailscale = s.service("system/tailscaled.service")
        val restart = assertNotNull(ServiceActions.command(ServiceAction.RESTART, tailscale))
        assertTrue(restart.isMutating)
        assertTrue(restart.root)
        assertEquals("\$S systemctl restart 'tailscaled.service' && echo \"Now: \$(systemctl is-active 'tailscaled.service')\"", restart.script)
        assertNotNull(restart.preview)
        assertNotNull(restart.warning, "stopping Tailscale can cut the connection")
        assertTrue(restart.readableScript().startsWith("sudo systemctl restart"))

        val gateway = s.service("user/hermes-gateway.service")
        val stop = assertNotNull(ServiceActions.command(ServiceAction.STOP, gateway))
        assertFalse(stop.root)
        assertTrue(stop.script.startsWith("systemctl --user stop 'hermes-gateway.service'"))
        assertEquals("journalctl --user -u 'hermes-gateway.service' -n 200 --no-pager", ServiceActions.command(ServiceAction.LOGS, gateway)?.script)
        assertFalse(assertNotNull(ServiceActions.command(ServiceAction.LOGS, tailscale)).isMutating)
        assertEquals("journalctl --user -u 'hermes-gateway.service' -f -n 100", ServiceActions.followLogsCommand(gateway))
        assertTrue(ServiceActions.followLogsCommand(tailscale)?.contains("sudo journalctl -u 'tailscaled.service' -f") ?: false)

        // Processes started by hand have no actions.
        val paperclip = s.service("process/paperclipai")
        assertNull(ServiceActions.command(ServiceAction.RESTART, paperclip))
        assertNull(ServiceActions.followLogsCommand(paperclip))

        assertTrue(ServiceActions.isUnitName("systemd-fsck@dev-disk-by\\x2duuid-77ED.service"))
        assertFalse(ServiceActions.isUnitName("-x.service"))
        assertFalse(ServiceActions.isUnitName("a b.service"))
        assertFalse(ServiceActions.isUnitName("a;reboot.service"))
        assertFalse(ServiceActions.isUnitName("a'b.service"))
        assertFalse(ServiceActions.isUnitName("nginx"))
        assertNull(ServiceActions.command(ServiceAction.RESTART, tailscale.copy(unit = "x\$(reboot).service")))
    }

    @Test fun actionsThatApply() {
        val s = fixture("synthetic-root-failed")
        val failed = s.service("system/backup-sync.service")
        val running = s.service("system/nginx.service")
        assertTrue(ServiceAction.START.appliesTo(failed))
        assertFalse(ServiceAction.STOP.appliesTo(failed))
        assertFalse(ServiceAction.START.appliesTo(running))
        assertTrue(ServiceAction.RESTART.appliesTo(running))
    }

    /** The restart command really does what it says through a shell, with a stub systemctl. */
    @Test fun restartRunsThroughARealShell() {
        val dir = Files.createTempDirectory("svc-").toFile()
        try {
            val stub = dir.resolve("systemctl")
            stub.writeText("#!/bin/sh\necho \"\$@\" >> \"${dir.path}/calls\"\ncase \"\$*\" in *is-active*) echo active;; esac\nexit 0\n")
            stub.setExecutable(true)
            val gateway = fixture("ubuntu-user-units-and-processes").service("user/hermes-gateway.service")
            val script = assertNotNull(ServiceActions.command(ServiceAction.RESTART, gateway)?.fullScript())
            val body = script.replace("PATH=\"\$PATH:/usr/local/sbin:/usr/sbin:/sbin\"; export PATH; ", "")
            val proc = ProcessBuilder("/bin/sh", "-c", "PATH=\"${dir.path}:\$PATH\"; $body").start()
            val out = proc.inputStream.readBytes().toString(Charsets.UTF_8)
            assertTrue(proc.waitFor(10, TimeUnit.SECONDS))
            assertEquals(0, proc.exitValue())
            assertEquals("Now: active\n", out)
            assertEquals(
                "--user restart hermes-gateway.service\n--user is-active hermes-gateway.service\n",
                dir.resolve("calls").readText(),
            )
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test fun sessionKeepsLastSnapshotOnFailure() = runTest {
        val good = Spec.out("services", "synthetic-root-failed")
        val transport = FakeTransport(listOf(ok(good), ok("", stderr = "Connection closed", exitCode = 255)))
        val session = ServicesSession(transport, clock = { 1L })
        val first = session.refresh()
        assertNotNull(first.snapshot)
        assertNull(first.error)
        val second = session.refresh()
        assertEquals(first.snapshot, second.snapshot)
        assertEquals("Connection closed", second.error)
        assertEquals(ServicesSession.command, transport.commands.first())
    }
}
