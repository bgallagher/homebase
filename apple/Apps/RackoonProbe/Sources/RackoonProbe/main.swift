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
        await session.perform(.start, containerID: running.id)
        state = await session.state
        print("no-op start of \(running.name): actionError=\(state.actionError ?? "none"), busy=\(state.busy.count)")
    }
    await session.perform(.start, containerID: "0123456789ab")
    state = await session.state
    print("start of nonexistent id: actionError=\(state.actionError ?? "none")")
    await session.perform(.restart, containerID: "x; reboot")
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
