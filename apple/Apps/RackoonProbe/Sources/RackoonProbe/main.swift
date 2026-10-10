import Foundation
import RackoonCore
import RackoonSSHSystem

// Headless check of OpenSSHTransport: `swift run rackoon-probe <host> [command]`
let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: rackoon-probe <host> [command]\n".utf8))
    exit(2)
}
if args.count > 2, args[2] == "hostkey" {
    // Uses a throwaway known_hosts file, never ~/.ssh/known_hosts.
    let path = NSTemporaryDirectory() + "probe-known-hosts-\(getpid())"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let verifier = HostKeyVerifier(knownHostsPath: path)
    let server = Server(name: args[1], host: args[1])
    func show(_ s: HostKeyStatus) -> String {
        switch s {
        case .trusted: "trusted"
        case .unknown(let o): "unknown, \(o.hostname):\(o.port)\n  " + o.fingerprints.joined(separator: "\n  ")
        case .changed(let m): "CHANGED: \(m)"
        case .failed(let m): "failed: \(m)"
        }
    }
    let first = await verifier.check(server)
    print("1. empty known_hosts -> \(show(first))")
    guard case .unknown(let offer) = first else { exit(1) }
    try verifier.trust(offer)
    print("2. after trust       -> \(show(await verifier.check(server)))")
    // Tamper: replace the stored key with a different one; must be reported as changed, never offered.
    let tampered = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map { line -> String in
        var f = line.split(separator: " ").map(String.init)
        guard f.count >= 3 else { return String(line) }
        var chars = Array(f[2])
        let i = chars.count - 6                      // inside the key blob, clear of any padding
        chars[i] = chars[i] == "A" ? "B" : "A"
        f[2] = String(chars)
        return f.joined(separator: " ")
    }.joined(separator: "\n") + "\n"
    try tampered.write(toFile: path, atomically: true, encoding: .utf8)
    print("3. tampered key      -> \(show(await verifier.check(server)))")
    exit(0)
}
let transport = OpenSSHTransport(host: args[1])
if args.count > 2, args[2] == "compose-test" {
    // Exercises the REAL compose actions end to end on a throwaway stack that this probe creates and removes.
    // It never touches your own stacks: everything lives under one temp directory and one project name.
    let project = "rackoon-probe-test"
    let dir = "/tmp/rackoon-probe-stack"
    let file = "\(dir)/compose.yaml"
    func sh(_ script: String, timeout: TimeInterval = 300) async -> CommandResult {
        (try? await transport.run(script, timeout: timeout)) ?? CommandResult(stdout: "", stderr: "ssh failed", exitCode: 255)
    }
    func teardown() async {
        _ = await sh("cd \(dir) 2>/dev/null && docker compose -p \(project) -f \(file) down -v --remove-orphans --rmi local 2>&1; cd /; rm -rf \(dir)")
    }
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL") \(what)"); if !ok { failures += 1 } }

    await teardown()
    let setup = await sh("""
    mkdir -p \(dir)/b && cd \(dir) && \
    printf 'FROM busybox:1.36\\nRUN echo built > /built.txt\\nCMD sleep 3600\\n' > b/Dockerfile && \
    printf 'services:\\n  web:\\n    image: busybox:1.36\\n    command: sleep 3600\\n  built:\\n    build: ./b\\n' > compose.yaml && \
    docker compose -p \(project) -f \(file) up -d --build 2>&1
    """, timeout: 600)
    check(setup.exitCode == 0, "setup stack up (exit \(setup.exitCode)) \(setup.exitCode == 0 ? "" : setup.stdout.suffix(300))")
    guard setup.exitCode == 0 else { await teardown(); exit(1) }

    let policy = ActionPolicy()
    let session = DockerSession(transport: transport, policy: policy)
    func theStack() async -> DockerStack? {
        await session.refresh()
        return await session.state.snapshot?.stacks.first { $0.name == project }
    }
    func ids(_ s: DockerStack?) -> Set<String> { Set((s?.containers ?? []).map(\.id)) }

    var stack = await theStack()
    check(stack?.containers.count == 2, "probe stack is listed with 2 containers")
    check(stack?.configFiles == [file], "config file label parsed: \(stack?.configFiles ?? [])")
    guard var current = stack else { await teardown(); exit(1) }
    let original = ids(current)

    func run(_ action: ComposeAction) async -> String? {
        let t0 = Date()
        await session.perform(action, stack: current, confirmation: try? session.confirm(action, stack: current))
        let state = await session.state
        print("   \(action.rawValue) took \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        check(state.busyStacks.isEmpty && state.busy.isEmpty, "\(action.rawValue): busy cleared afterwards")
        return state.actionError
    }

    check(await run(.pull) == nil, "pull succeeds")
    stack = await theStack(); current = stack ?? current
    check(ids(stack) == original, "pull leaves containers untouched")

    check(await run(.up) == nil, "update (up -d) succeeds")
    stack = await theStack(); current = stack ?? current
    check(ids(stack) == original, "update with nothing changed keeps the same containers")

    check(await run(.rebuild) == nil, "rebuild succeeds")
    stack = await theStack(); current = stack ?? current
    check(stack?.containers.count == 2 && stack?.containers.allSatisfy(\.isRunning) == true, "rebuild leaves 2 running containers")

    let beforeRecreate = ids(stack)
    check(await run(.recreate) == nil, "recreate succeeds")
    stack = await theStack(); current = stack ?? current
    check(ids(stack).isDisjoint(with: beforeRecreate) && ids(stack).count == 2, "recreate gives every container a new id")
    check(stack?.containers.allSatisfy(\.isRunning) == true, "recreated containers are running")

    policy.isReadOnly = true
    let blocked = await run(.recreate)
    check(blocked == PolicyError.readOnly.errorDescription, "read-only mode refuses a real stack action: \(blocked ?? "nil")")
    policy.isReadOnly = false
    check(ids(await theStack()) == ids(stack), "nothing changed while read-only")

    await teardown()
    let leftover = await sh("docker ps -a --filter label=com.docker.compose.project=\(project) -q | wc -l; ls \(dir) 2>&1 | head -1")
    check(leftover.stdout.hasPrefix("0"), "teardown removed the containers and directory (\(leftover.stdout.replacingOccurrences(of: "\n", with: " | ")))")
    print(failures == 0 ? "compose-test: all passed" : "compose-test: \(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
if args.count > 2, args[2] == "updates" {
    let session = UpdatesSession(transport: transport)
    let t0 = Date()
    let state = await session.refresh()
    print("updates poll: \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    if let e = state.error { print("error: \(e)"); exit(1) }
    guard let snap = state.snapshot else { exit(1) }
    print("\(snap.packages.count) upgradable, \(snap.securityCount) security, \(snap.held.count) held, reboot required: \(snap.rebootRequired)")
    if let t = snap.refreshedAt { print("package lists refreshed \(Date(timeIntervalSince1970: TimeInterval(t)))") }
    for p in snap.packages.prefix(10) { print("   \(p.isSecurity ? "SEC" : "   ") \(p.name) \(p.oldVersion ?? "?") -> \(p.newVersion)") }
    exit(0)
}
if args.count > 2, args[2] == "docker" {
    let session = DockerSession(transport: transport)
    let t0 = Date()
    await session.refresh()
    print("docker poll: \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    var state = await session.state
    if let e = state.error { print("error: \(e)"); exit(1) }
    guard let snap = state.snapshot else { exit(1) }
    for stack in snap.stacks {
        print("\(stack.name) (\(stack.configFileName ?? "-")): \(stack.runningCount) running, \(stack.unhealthyCount) unhealthy, \(stack.stoppedCount) stopped")
        for c in stack.containers {
            print("   \(c.service ?? c.name) [\(c.state)/\(c.health)] cpu \(c.cpuPercent.map { String(format: "%.1f", $0) } ?? "-")% mem \(c.memoryUsedBytes.map { "\($0 / 1_048_576)MiB" } ?? "-") ports \(c.ports.map { "\($0.hostPort)->\($0.containerPort)" })")
        }
    }
    // Harmless: starting an already-running container is a no-op that echoes its id.
    if let running = snap.containers.first(where: { $0.isRunning }) {
        await session.perform(.start, containerID: running.id, confirmation: try? session.confirm(.start, containerID: running.id))
        state = await session.state
        print("no-op start of \(running.name): actionError=\(state.actionError ?? "none"), busy=\(state.busy.count)")
    }
    // Harmless: prove the compose command (cd, quoting, -p, -f) resolves on this host with `config -q`, which
    // validates the file and changes nothing. The real pull/up/recreate commands are never run by the probe.
    for stack in snap.stacks where !stack.isStandalone {
        guard let pull = ComposeAction.pull.command(for: stack) else { print("compose \(stack.name): no usable command"); continue }
        let check = pull.replacingOccurrences(of: " pull", with: " config -q", options: .backwards)
        let r = try? await transport.run(check, timeout: 30)
        print("compose \(stack.name): config check exit \(r.map { String($0.exitCode) } ?? "failed")\((r?.stderr.isEmpty ?? true) ? "" : " " + r!.stderr.prefix(120))")
    }
    await session.perform(.start, containerID: "0123456789ab", confirmation: try? session.confirm(.start, containerID: "0123456789ab"))
    state = await session.state
    print("start of nonexistent id: actionError=\(state.actionError ?? "none")")
    await session.perform(.restart, containerID: "x; reboot", confirmation: try? session.confirm(.restart, containerID: "x; reboot"))
    state = await session.state
    print("injection attempt: actionError=\(state.actionError ?? "none")")
    exit(0)
}
if args.count > 3, args[2] == "logs" {
    // Stream a container's logs for 4 s, cancel, then check nothing is left running on the server.
    let name = args[3]
    let task = Task {
        var bytes = 0
        do {
            for try await chunk in transport.stream("docker logs -f --tail 3 \(name)") {
                bytes += chunk.utf8.count
                print("chunk:", chunk.replacingOccurrences(of: "\r", with: "<CR>").prefix(120))
            }
        } catch { print("stream error: \(error)") }
        return bytes
    }
    try await Task.sleep(nanoseconds: 4_000_000_000)
    task.cancel()
    _ = await task.value
    try await Task.sleep(nanoseconds: 1_500_000_000)
    let r = try await transport.run("pgrep -af 'docker logs' | grep -v pgrep | wc -l", timeout: 10)
    print("remote 'docker logs' processes still running: \(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
    exit(0)
}
if args.count > 2, args[2] == "overview" {
    // Two polls through the real ServerSession, so CPU% (needs two readings) is exercised.
    let session = ServerSession(transport: transport)
    let t0 = Date()
    await session.refresh()
    print("first poll: \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    try await Task.sleep(nanoseconds: 3_000_000_000)
    let t1 = Date()
    await session.refresh()
    print("second poll: \(String(format: "%.2f", Date().timeIntervalSince(t1)))s")
    let state = await session.state
    if let e = state.error { print("error: \(e)"); exit(1) }
    if let o = state.overview {
        print("\(o.hostname) · \(o.os.prettyName) · cores \(o.cores) · load \(o.load1) · up \(Int(o.uptimeSeconds / 3600))h")
        print("cpu \(state.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "n/a") · mem \(o.memory.usedBytes / 1_048_576) / \(o.memory.totalBytes / 1_048_576) MiB")
        for d in o.disks { print("disk \(d.mount) \(d.usePercent)%") }
        print("reboot required: \(o.rebootRequired) · attention: \(state.attention.map(\.message))")
    }
    exit(0)
}
let command = args.count > 2 ? args[2] : "uname -a"
do {
    let start = Date()
    let first = try await transport.run(command, timeout: 15)
    let t1 = Date().timeIntervalSince(start)
    print("exit \(first.exitCode) in \(String(format: "%.2f", t1))s")
    print(first.stdout, terminator: "")
    if !first.stderr.isEmpty { print("stderr: \(first.stderr)") }

    let start2 = Date()
    _ = try await transport.run(command, timeout: 15)
    print("second call (multiplexed): \(String(format: "%.2f", Date().timeIntervalSince(start2)))s")

    var lines = 0
    for try await chunk in transport.stream("for i in 1 2 3; do echo tick $i; sleep 0.3; done") {
        lines += chunk.split(separator: "\n").count
        print("stream:", chunk.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    print("stream lines: \(lines)")
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
