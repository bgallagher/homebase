import Foundation

/// What can be done to a discovered systemd service. Each action is built as a `LibraryCommand`, so it runs exactly like
/// a Commands-tab entry: reads stream straight away, changes (`start`/`stop`/`restart`) show a read-only status first and
/// then the standard confirmation, are refused in Read-only mode, and system units go through `sudo -n` with the sudo
/// password sheet when sudo wants a password. A user unit (`systemctl --user`) needs no sudo.
///
/// Processes started by hand have no actions: nothing on the server knows how to start one again.
public enum ServiceAction: String, Sendable, CaseIterable {
    case start, stop, restart, status, logs

    public var title: String {
        switch self {
        case .start: "Start"
        case .stop: "Stop"
        case .restart: "Restart"
        case .status: "Status"
        case .logs: "Recent Logs"
        }
    }

    public var isMutating: Bool { self == .start || self == .stop || self == .restart }

    /// Whether the action makes sense for a service in this state.
    public func applies(to service: DiscoveredService) -> Bool {
        switch self {
        case .start: service.status == .stopped || service.status == .failed
        case .stop: service.status != .stopped && service.status != .failed
        case .restart: service.status != .stopping
        case .status, .logs: true
        }
    }
}

public enum ServiceActions {
    /// A unit name that is safe to hand to systemctl (it is quoted as well): letters, digits and `:_.@-\`, ending in
    /// `.service`, not starting with `-` (an option).
    public static func isUnitName(_ name: String) -> Bool {
        guard name.hasSuffix(".service"), !name.hasPrefix("-"), name.count <= 256 else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || ":_.@-\\".unicodeScalars.contains($0) }
    }

    /// The command for `action` on `service`, or nil for a process or a name that is not safe.
    public static func command(_ action: ServiceAction, for service: DiscoveredService) -> LibraryCommand? {
        guard let unit = service.unit, isUnitName(unit), let q = ShellQuote.quote(unit) else { return nil }
        let user = service.kind == .user
        let ctl = user ? "systemctl --user" : "$S systemctl"
        // A system unit's journal is readable without sudo by root and members of adm or systemd-journal.
        let journalReader = #"[ "$(id -u)" -eq 0 ] || id -nG | tr ' ' '\n' | grep -qxE 'adm|systemd-journal|wheel'"#
        let id = "service.\(action.rawValue).\(service.id)"
        let title = "\(action.title) \(service.name)"
        let status = "systemctl\(user ? " --user" : "") status --no-pager --lines=5 \(q) 2>&1 | head -n 20; true"
        switch action {
        case .start, .stop, .restart:
            return LibraryCommand(
                id: id, title: title, group: "Services",
                summary: summary(action, service),
                script: "\(ctl) \(action.rawValue) \(q) && echo \"Now: $(systemctl\(user ? " --user" : "") is-active \(q))\"",
                risk: .mutate, root: !user, preview: status,
                warning: action == .start ? nil : warning(service))
        case .status:
            return LibraryCommand(id: id, title: title, group: "Services", summary: "What systemd says about \(unit) now.",
                                  script: "systemctl\(user ? " --user" : "") status --no-pager --lines=30 \(q); true")
        case .logs:
            let script = user
                ? "journalctl --user -u \(q) -n 200 --no-pager"
                : "if \(journalReader); then journalctl -u \(q) -n 200 --no-pager; else $S journalctl -u \(q) -n 200 --no-pager; fi"
            return LibraryCommand(id: id, title: title, group: "Services", summary: "The last 200 lines \(unit) wrote to the journal.",
                                  script: script, root: !user)
        }
    }

    /// Follows the unit's journal in a terminal tab. For a system unit the user can't read, `sudo` asks in the terminal.
    public static func followLogsCommand(for service: DiscoveredService) -> String? {
        guard let unit = service.unit, isUnitName(unit), let q = ShellQuote.quote(unit) else { return nil }
        if service.kind == .user { return "journalctl --user -u \(q) -f -n 100" }
        return #"if [ "$(id -u)" -eq 0 ] || id -nG | tr ' ' '\n' | grep -qxE 'adm|systemd-journal|wheel'; then "#
            + "journalctl -u \(q) -f -n 100; else sudo journalctl -u \(q) -f -n 100; fi"
    }

    static func summary(_ action: ServiceAction, _ service: DiscoveredService) -> String {
        let unit = service.unit ?? service.name
        let how = service.kind == .user ? "with systemctl --user (your own service, no sudo)" : "with systemctl (needs sudo)"
        return switch action {
        case .start: "Starts \(unit) \(how)."
        case .stop: "Stops \(unit) \(how). It starts again at the next boot if it is enabled."
        default: "Stops and starts \(unit) \(how)."
        }
    }

    /// What stopping this one costs, for the products where that is not obvious.
    static func warning(_ service: DiscoveredService) -> String? {
        switch service.product {
        case "tailscale": "If you reach this server over Tailscale, the connection drops until it is back (Rackoon included)."
        case "ssh": "Rackoon talks to this server over ssh. Open sessions usually survive, but new ones are refused while it is down."
        case "docker": "Every container on this server stops with it."
        case "wireguard", "netbird", "zerotier", "openvpn", "cloudflared": "Anything reaching this server through it loses access until it is back."
        default: nil
        }
    }
}
