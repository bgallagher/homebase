import Foundation

/// A value a library command asks for before it runs (a container to look at, a host to check).
public struct LibraryParam: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case container, hostname }
    public var id: String
    public var label: String
    public var kind: Kind
    public var placeholder: String

    public init(id: String, label: String, kind: Kind, placeholder: String = "") {
        self.id = id
        self.label = label
        self.kind = kind
        self.placeholder = placeholder
    }

    /// The value shell-quoted, or nil if it is not a valid value of this kind. Nothing else ever reaches the shell.
    public func quoted(_ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .container:
            // A container name or id: letters, digits, `_`, `.`, `-`, starting with a letter or digit.
            guard let f = v.first, f.isASCII, f.isLetter || f.isNumber, v.count <= 128,
                  v.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }) else { return nil }
        case .hostname:
            guard v.count <= 253, !v.hasPrefix("-"), !v.hasPrefix("."), !v.hasSuffix("."), !v.hasSuffix("-"), !v.contains(".."),
                  v.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-.".contains($0)) }), !v.isEmpty else { return nil }
        }
        return ShellQuote.quote(v)
    }
}

/// One entry of the Commands tab's library. `risk == .read` runs straight away; `.mutate` shows a preview (the output of
/// `preview`, a read-only dry run) and asks first. Mirrors spec/command-library.json; a test keeps them equal.
public struct LibraryCommand: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var group: String
    public var summary: String
    /// A shell script; `{param}` placeholders are filled with validated, quoted values and `$S` stands for `sudo -n` (or
    /// nothing when the ssh user is root) in entries marked `root`.
    public var script: String
    public var risk: Risk
    public var root: Bool
    /// A program the script needs (`docker`, `tailscale`...). Without it the script prints "X is not installed" and stops.
    public var needs: String?
    /// A read-only dry run whose output is shown in the confirmation sheet (mutating entries).
    public var preview: String?
    /// Extra caution shown in the confirmation sheet.
    public var warning: String?
    public var params: [LibraryParam]
    /// Endless or interactive: opened in a terminal tab instead of streamed into the output panel.
    public var interactive: Bool

    public init(id: String, title: String, group: String, summary: String, script: String, risk: Risk = .read, root: Bool = false,
                needs: String? = nil, preview: String? = nil, warning: String? = nil, params: [LibraryParam] = [], interactive: Bool = false) {
        self.id = id
        self.title = title
        self.group = group
        self.summary = summary
        self.script = script
        self.risk = risk
        self.root = root
        self.needs = needs
        self.preview = preview
        self.warning = warning
        self.params = params
        self.interactive = interactive
    }

    /// The runnable script (or preview script) with its guards, or nil if a parameter is missing or invalid.
    public func fullScript(_ body: String? = nil, params values: [String: String] = [:]) -> String? {
        var filled: [String: String] = [:]
        for p in params {
            guard let q = p.quoted(values[p.id] ?? "") else { return nil }
            filled[p.id] = q
        }
        // A non-root ssh command gets a minimal PATH on Debian, without the sbin directories (ufw, swapon, fail2ban-client...),
        // so a "not installed" answer would be wrong. `sudo -n` has its own secure_path.
        var out = #"PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"; export PATH; "#
        if root { out += #"if [ "$(id -u)" -eq 0 ]; then S=; else S='sudo -n'; fi; "# }
        if let needs { out += "command -v \(needs) >/dev/null 2>&1 || { echo '\(needs) is not installed on this server.'; exit 0; }; " }
        return out + Template.fill(body ?? script, filled)
    }

    public var isMutating: Bool { risk == .mutate }
}

public enum CommandLibrary {
    public static let groups = ["Disk", "Performance", "Docker", "Network", "Logs and system", "Security", "Maintenance"]

    public static func commands(in group: String) -> [LibraryCommand] { all.filter { $0.group == group } }

    private static let table = "table {{.Names}}\\t{{.Status}}\\t{{.Image}}"

    public static let all: [LibraryCommand] = [
        // MARK: Disk
        LibraryCommand(id: "disk_usage", title: "Disk usage", group: "Disk", summary: "Space and inodes on every real disk.",
                       script: "df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay; echo; echo 'Inodes:'; df -i -x tmpfs -x devtmpfs -x squashfs -x overlay"),
        LibraryCommand(id: "biggest_folders", title: "Biggest folders", group: "Disk", summary: "The 15 largest top-level folders on /. Can take a minute.",
                       script: "$S du -xh --max-depth=1 / 2>&1 | grep -v 'Permission denied' | sort -rh | head -15", root: true),
        LibraryCommand(id: "docker_disk", title: "Docker disk use", group: "Disk", summary: "Images, containers, volumes and build cache, and what is reclaimable.",
                       script: "docker system df", needs: "docker"),
        LibraryCommand(id: "journal_size", title: "Journal size", group: "Disk", summary: "How much space the system journal uses.",
                       script: "journalctl --disk-usage"),
        // MARK: Performance
        LibraryCommand(id: "top_cpu", title: "Top processes by CPU", group: "Performance", summary: "The 15 busiest processes right now.",
                       script: "ps -eo pid,user,%cpu,%mem,etime,comm --sort=-%cpu | head -16"),
        LibraryCommand(id: "top_memory", title: "Top processes by memory", group: "Performance", summary: "The 15 processes using the most memory.",
                       script: "ps -eo pid,user,%cpu,%mem,rss,comm --sort=-%mem | head -16"),
        LibraryCommand(id: "memory", title: "Memory and swap", group: "Performance", summary: "Used, free and cached memory, and swap.",
                       script: "free -h; echo; echo 'Swap devices:'; swapon --show 2>/dev/null || echo none"),
        LibraryCommand(id: "load", title: "Load and uptime", group: "Performance", summary: "Load averages next to the number of cores.",
                       script: "uptime; echo; echo \"cores: $(nproc)\""),
        LibraryCommand(id: "container_stats", title: "Container resource use", group: "Performance", summary: "CPU, memory and network per running container, one reading.",
                       script: "docker stats --no-stream", needs: "docker"),
        LibraryCommand(id: "live_top", title: "Live processes (top)", group: "Performance", summary: "Opens top in a terminal tab.",
                       script: "top", interactive: true),
        // MARK: Docker
        LibraryCommand(id: "containers_all", title: "All containers", group: "Docker", summary: "Every container with its status and image.",
                       script: "docker ps -a --format '\(table)'", needs: "docker"),
        LibraryCommand(id: "containers_problems", title: "Stopped, restarting or unhealthy", group: "Docker", summary: "Containers that are not running as they should.",
                       script: "docker ps -a --filter status=exited --filter status=restarting --filter status=dead --format '\(table)'; echo; echo 'Unhealthy:'; docker ps --filter health=unhealthy --format '\(table)'",
                       needs: "docker"),
        LibraryCommand(id: "restart_counts", title: "Restart counts", group: "Docker", summary: "How many times each container has restarted.",
                       script: "docker ps -a --format '{{.Names}}' | while read -r n; do printf '%s: ' \"$n\"; docker inspect -f '{{.RestartCount}} restarts ({{.State.Status}})' \"$n\"; done",
                       needs: "docker"),
        LibraryCommand(id: "container_logs", title: "Container logs (last 200 lines)", group: "Docker", summary: "The tail of one container's log.",
                       script: "docker logs --tail 200 {container} 2>&1", needs: "docker",
                       params: [LibraryParam(id: "container", label: "Container", kind: .container, placeholder: "container name")]),
        LibraryCommand(id: "images", title: "Images", group: "Docker", summary: "Local images with their size, and how many are dangling.",
                       script: "docker images --format 'table {{.Repository}}\\t{{.Tag}}\\t{{.Size}}\\t{{.CreatedSince}}'; echo; echo \"Dangling images: $(docker images -f dangling=true -q | wc -l)\"",
                       needs: "docker"),
        LibraryCommand(id: "volumes", title: "Volumes", group: "Docker", summary: "Docker volumes on this server.", script: "docker volume ls", needs: "docker"),
        LibraryCommand(id: "docker_events", title: "Recent Docker events", group: "Docker", summary: "What Docker did in the last hour (starts, stops, dies).",
                       script: "docker events --since 1h --until \"$(date +%s)\" 2>&1 | tail -50", needs: "docker"),
        // MARK: Network
        LibraryCommand(id: "listening_ports", title: "Listening ports", group: "Network", summary: "What is listening, and which process owns it.",
                       script: "$S ss -tulpn", root: true),
        LibraryCommand(id: "addresses", title: "Addresses and routes", group: "Network", summary: "Interfaces with their addresses, and the default routes.",
                       script: "ip -br addr; echo; ip route | head -5"),
        LibraryCommand(id: "tailscale_status", title: "Tailscale status", group: "Network", summary: "This node and its peers.",
                       script: "tailscale status", needs: "tailscale"),
        LibraryCommand(id: "public_ip", title: "Public IP", group: "Network", summary: "The address the internet sees for this server.",
                       script: "curl -s --max-time 5 https://ifconfig.me || curl -s --max-time 5 https://icanhazip.com; echo", needs: "curl"),
        LibraryCommand(id: "dns_check", title: "DNS check", group: "Network", summary: "Resolver settings, and whether names resolve.",
                       script: "cat /etc/resolv.conf; echo; for h in github.com cloudflare.com; do printf '%s -> ' \"$h\"; getent hosts \"$h\" | head -1 || echo FAILED; done"),
        LibraryCommand(id: "cert_expiry", title: "Certificate expiry", group: "Network", summary: "Who issued a site's certificate and when it expires.",
                       script: "echo | openssl s_client -servername {host} -connect {host}:443 2>/dev/null | openssl x509 -noout -subject -issuer -dates", needs: "openssl",
                       params: [LibraryParam(id: "host", label: "Host", kind: .hostname, placeholder: "app.example.com")]),
        // MARK: Logs and system
        LibraryCommand(id: "recent_errors", title: "Recent errors", group: "Logs and system", summary: "Error-level messages from this boot, newest last.",
                       script: "$S journalctl -p err -b -n 100 --no-pager", root: true),
        LibraryCommand(id: "failed_services", title: "Failed services", group: "Logs and system", summary: "systemd units that are in a failed state.",
                       script: "systemctl --failed --no-pager"),
        LibraryCommand(id: "kernel_messages", title: "Kernel messages", group: "Logs and system", summary: "The last 50 kernel log lines.",
                       script: "$S dmesg --ctime 2>&1 | tail -50", root: true),
        LibraryCommand(id: "logins", title: "Who is logged in, and recent logins", group: "Logs and system", summary: "Current sessions and the last 10 logins.",
                       script: "w; echo; last -n 10 -a"),
        LibraryCommand(id: "follow_journal", title: "Follow the system log", group: "Logs and system", summary: "Opens journalctl -f in a terminal tab.",
                       script: "$S journalctl -f", root: true, interactive: true),
        // MARK: Security
        LibraryCommand(id: "fail2ban", title: "Fail2ban status", group: "Security", summary: "Jails, and who is banned in the SSH jail.",
                       script: "$S fail2ban-client status; echo; $S fail2ban-client status sshd 2>/dev/null", root: true, needs: "fail2ban-client"),
        LibraryCommand(id: "firewall", title: "Firewall status", group: "Security", summary: "ufw rules, if ufw is installed.",
                       script: "$S ufw status verbose", root: true, needs: "ufw"),
        LibraryCommand(id: "failed_ssh", title: "Failed SSH logins (24 h)", group: "Security", summary: "Rejected passwords and unknown users in the last day.",
                       script: "$S journalctl -u ssh -u sshd --since '24 hours ago' --no-pager 2>&1 | grep -iE 'Failed password|Invalid user|sudo:|not allowed|permission' | tail -30; echo; echo '(last 24 hours; nothing above means none)'", root: true),
        LibraryCommand(id: "security_updates", title: "Pending security updates", group: "Security", summary: "From the package lists already on the server.",
                       script: "apt list --upgradable 2>/dev/null | grep -i security || echo 'No pending security updates in this server'\\''s package lists.'"),
        LibraryCommand(id: "autoremove_preview", title: "Unused packages", group: "Security", summary: "What apt autoremove would remove (a simulation; nothing is removed).",
                       script: "apt-get -s autoremove | grep -E '^Remv|to remove|^[0-9]+ upgraded'"),
        // MARK: Maintenance (asks first)
        LibraryCommand(id: "docker_prune", title: "Prune unused Docker data", group: "Maintenance",
                       summary: "Removes stopped containers, unused networks, dangling images and unused build cache. Volumes are kept.",
                       script: "docker system prune -f", risk: .mutate, needs: "docker",
                       preview: "docker ps -a --filter status=exited --filter status=dead --filter status=created --format 'Stopped container: {{.Names}}'; docker network ls --format '{{.ID}} {{.Name}}' | while read -r id name; do case \"$name\" in bridge|host|none) continue;; esac; [ \"$(docker network inspect -f '{{len .Containers}}' \"$id\")\" = 0 ] && echo \"Unused network: $name\"; done; docker images -f dangling=true --format 'Dangling image: {{.ID}} ({{.Size}})'; echo; echo 'Build cache and totals:'; docker system df"),
        LibraryCommand(id: "apt_clean", title: "Clear the apt download cache", group: "Maintenance", summary: "Deletes downloaded .deb files in /var/cache/apt/archives. Installed packages are not touched.",
                       script: "$S apt-get clean && du -sh /var/cache/apt/archives", risk: .mutate, root: true,
                       preview: "du -sh /var/cache/apt/archives; ls /var/cache/apt/archives/*.deb 2>/dev/null | wc -l | sed 's/$/ cached packages/'"),
        LibraryCommand(id: "journal_vacuum", title: "Trim the journal to 7 days", group: "Maintenance", summary: "Deletes journal entries older than a week.",
                       script: "$S journalctl --vacuum-time=7d", risk: .mutate, root: true, preview: "journalctl --disk-usage"),
        LibraryCommand(id: "restart_tailscale", title: "Restart Tailscale", group: "Maintenance", summary: "Restarts the tailscaled service.",
                       script: "$S systemctl restart tailscaled", risk: .mutate, root: true, needs: "tailscale",
                       preview: "tailscale status | head -5",
                       warning: "If Rackoon reaches this server over Tailscale, its connection drops while the service restarts. It comes back on its own in a few seconds."),
        LibraryCommand(id: "restart_docker", title: "Restart the Docker service", group: "Maintenance", summary: "Restarts the Docker daemon.",
                       script: "$S systemctl restart docker", risk: .mutate, root: true, needs: "docker",
                       preview: "docker ps --format 'Will be interrupted: {{.Names}}'",
                       warning: "Every running container stops and starts again (unless Docker's live-restore is on). Containers without a restart policy stay stopped."),
    ]
}

/// Builds intents for library and custom commands and runs them with live output. Reading runs straight away; anything that
/// changes the server needs a `Confirmation` for exactly that command, checked again here.
public actor CommandLibrarySession {
    private let transport: SSHTransport
    private let policy: ActionPolicy

    public init(transport: SSHTransport, policy: ActionPolicy = ActionPolicy()) {
        self.transport = transport
        self.policy = policy
    }

    /// The intent for a library entry. `preview` is the dry-run output the user saw (part of the intent, so a confirmation
    /// only matches what was shown).
    public nonisolated func intent(for command: LibraryCommand, params: [String: String] = [:], preview: String? = nil) -> Intent? {
        guard let script = command.fullScript(params: params) else { return nil }
        return Intent(summary: command.title, command: script, risk: command.risk, preview: preview)
    }

    /// Anything typed by hand. It can't be classified, so it counts as a change and always needs a confirmation.
    public nonisolated func customIntent(_ text: String) -> Intent? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 4000, !t.contains("\0") else { return nil }
        return Intent(summary: "Run a custom command", command: t, risk: .mutate)
    }

    public nonisolated func confirm(_ intent: Intent) throws -> Confirmation { try policy.confirm(intent) }

    /// Runs the dry-run script of a mutating entry (read-only) and returns its text, for the confirmation sheet.
    public func preview(for command: LibraryCommand, params: [String: String] = [:]) async -> String {
        guard let body = command.preview, let script = command.fullScript(body, params: params) else { return "" }
        guard let result = try? await transport.run(script, timeout: 30) else { return "Could not read the preview from the server." }
        return [result.stdout, result.stderr].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs `intent` with live output. Returns false without running if it needs a confirmation it does not have.
    @discardableResult
    public func run(_ intent: Intent, confirmation: Confirmation?, cols: Int, rows: Int,
                    onEvent: @escaping @Sendable (ActionStreamEvent) -> Void) async -> StreamedRun? {
        do { try policy.authorize(intent, with: confirmation) } catch {
            onEvent(.output("\u{1B}[31m\((error as? LocalizedError)?.errorDescription ?? "\(error)")\u{1B}[0m\r\n"))
            onEvent(.finished(exitCode: nil))
            return nil
        }
        return await StreamRunner.run(transport: transport, command: intent.command, cols: cols, rows: rows, onEvent: onEvent)
    }
}
