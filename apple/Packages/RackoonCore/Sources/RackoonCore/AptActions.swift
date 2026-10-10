import Foundation

/// State-changing apt operations. Each is a `.mutate` intent, so it needs a confirmation and respects read-only mode.
public enum AptAction: Sendable, Equatable {
    /// `apt-get update`: refreshes the package lists, installs nothing.
    case refresh
    /// `apt-get upgrade`: every available upgrade, no new packages, no removals, held packages stay.
    case upgradeAll
    /// Upgrade only these packages (used for "install security updates").
    case upgrade(packages: [String])

    static let prefix = "if [ \"$(id -u)\" -eq 0 ]; then S=; else S='sudo -n'; fi; $S env DEBIAN_FRONTEND=noninteractive apt-get "
    static let options = "-y -o Dpkg::Options::=--force-confold"

    public var timeout: TimeInterval { self == .refresh ? 300 : 1800 }

    /// The exact command, or nil if a package name is not a valid Debian package name (or the list is empty).
    public var command: String? {
        switch self {
        case .refresh: return Self.prefix + "update"
        case .upgradeAll: return Self.prefix + "upgrade " + Self.options
        case .upgrade(let packages):
            guard !packages.isEmpty, packages.allSatisfy(Self.isPackageName) else { return nil }
            return Self.prefix + "install --only-upgrade " + Self.options + " " + packages.joined(separator: " ")
        }
    }

    public var intent: Intent? {
        guard let command else { return nil }
        let summary: String
        switch self {
        case .refresh: summary = "Refresh package lists"
        case .upgradeAll: summary = "Install all available updates"
        case .upgrade(let packages): summary = "Install updates for \(packages.count) package\(packages.count == 1 ? "" : "s")"
        }
        return Intent(summary: summary, command: command, risk: .mutate)
    }

    /// Debian policy: lowercase letters, digits, `+`, `-`, `.`; at least two characters, starting alphanumeric.
    static func isPackageName(_ name: String) -> Bool {
        guard name.count >= 2, let first = name.first, first.isASCII, first.isLowercase || first.isNumber else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || "+-.".contains($0)) }
    }

    /// Turns sudo's complaint into something a person can act on.
    static func explain(stderr: String, exitCode: Int32) -> String {
        let lines = stderr.split(separator: "\n").map(String.init)
        if lines.contains(where: { $0.contains("a password is required") || $0.contains("not in the sudoers") || $0.contains("may not run sudo") }) {
            return "This user can't run apt with sudo without a password. Use root, or allow passwordless sudo for apt-get."
        }
        if lines.contains(where: { $0.contains("Could not get lock") || $0.contains("Unable to acquire the dpkg") }) {
            return "Another package manager is running on the server (apt lock held). Try again in a minute."
        }
        let tail = lines.suffix(3).joined(separator: "\n")
        return tail.isEmpty ? "apt-get failed (exit \(exitCode))" : tail
    }
}
