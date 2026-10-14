import Foundation

/// Running a root command for an ssh user whose sudo wants a password.
///
/// Every root script picks its sudo with `S='sudo -n'` (never prompts). When that is refused, the app asks for the
/// password and runs the same script again behind `prefix`: before the script starts, `sudo -v` asks for the password
/// ONCE with a prompt carrying a random per-run nonce, then prints an ok (or fail) marker with the same nonce. The
/// script's own `sudo -n` then uses the session record `sudo -v` just made. `SudoHandshake` types the password at that
/// one prompt and stops listening when a marker arrives, so nothing the script prints later (journal lines, user
/// names, process names: text other people on the server control) can make it type the password again.
/// The password is never part of a command, so it is not in `ps` on the server, the confirm sheet or any log.
public enum SudoElevation {
    /// What every root script contains (spec: `apt_*` scripts and the command library's root prefix).
    public static let noPassword = "S='sudo -n'"
    /// Equals the spec template `sudo_prompt`. `mesg n` stops other users on the server from writing into this session's
    /// terminal (`wall`, `write`), so nobody can fake sudo's prompt or a marker during the password step. `stty -echo`
    /// keeps anything typed outside sudo's own prompt from being shown; exit 7 means sudo refused and the script never ran.
    public static let prefix = #"if [ "$(id -u)" -ne 0 ]; then mesg n 2>/dev/null; stty -echo 2>/dev/null; sudo -p '##rackoon-sudo-{nonce}:' -v || { echo '##rackoon-sudo-fail-{nonce}'; exit 7; }; fi; echo '##rackoon-sudo-ok-{nonce}'; "#

    /// 16 random bytes as hex. The nonce is visible in `ps` on the server, so it is a second layer, not the protection:
    /// the protection is that only one prompt, before the script runs, is ever answered.
    public static func makeNonce() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
    }

    static func isNonce(_ s: String) -> Bool { s.count == 32 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase } }

    /// The script behind the password prefix, or nil if it does not use `$S` or the nonce is malformed.
    public static func withPassword(_ command: String, nonce: String) -> String? {
        guard command.contains(noPassword), isNonce(nonce) else { return nil }
        return Template.fill(prefix, ["nonce": nonce]) + command
    }

    /// True when sudo refused because it needed a password: classic sudo "a password is required" / "a terminal is
    /// required", sudo-rs "interactive authentication is required". Only used to OFFER the password sheet.
    public static func needsPassword(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            return line.hasPrefix("sudo:") && (line.contains("password is required") || line.contains("terminal is required")
                || line.contains("authentication is required"))
        }
    }

    /// sudo's words for a wrong password: classic "Sorry, try again." / "1 incorrect password attempt", sudo-rs
    /// "Authentication failed, try again." / "maximum 3 incorrect authentication attempts". Shared with the reboot.
    public static func isAuthFailure(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("sorry, try again") || t.contains("incorrect password") || t.contains("authentication failed")
            || t.contains("incorrect authentication") || t.contains("no password was provided") || t.contains("authentication required")
    }

    /// sudo said no for a reason other than a wrong password (what it printed before the fail marker), in plain words.
    public static func explainRefusal(_ sudoText: String) -> String {
        let text = sudoText.lowercased()
        if text.contains("not in the sudoers") || text.contains("not allowed to execute") || text.contains("not allowed to run sudo")
            || text.contains("may not run sudo") {
            return "This user is not allowed to use sudo on the server. Use root, or give the user sudo rights."
        }
        if text.contains("must have a tty") || text.contains("requiretty") {
            return "sudo on this server insists on a terminal, so Rackoon can't hand it the password. Allow passwordless sudo for this command, or run it in a terminal tab."
        }
        let lines = sudoText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.isEmpty ? "sudo refused, and said nothing about why." : "sudo refused: " + lines.joined(separator: " ")
    }

    /// sudo asked a second question after the password (a second factor, an expired password to change).
    public static let otherPrompt = "sudo asked for something besides the password (a second factor, or a password that must be changed), which Rackoon can't answer. Run the command in a terminal tab."

    /// sudo took the password, but the command's own `sudo -n` still wanted one (timestamp_timeout=0, or a sudo that
    /// keeps no session record). Typing it again for each command would mean answering prompts during the command.
    public static let asksEveryTime = "sudo on this server asks for the password for every command, so Rackoon can't pass it on safely. Allow passwordless sudo for this command, or run it in a terminal tab."
}

/// A sudo password and the nonce of the one prompt it may be typed at. Built once per attempt: the nonce is part of the
/// intent's command, so the confirmation and the run must use the same one.
public struct SudoCredential: Sendable {
    public let password: String
    public let nonce: String
    public init(password: String, nonce: String) {
        self.password = password
        self.nonce = nonce
    }
}

/// How the password step of a run ended.
public enum SudoOutcome: Sendable, Equatable {
    /// The ok marker arrived: sudo took the password (or the user is root) and the script ran.
    case accepted
    /// sudo asked a second time before the ok marker: the password was wrong. One Ctrl-C was sent; nothing was typed again.
    case rejected
    /// The fail marker arrived without a second prompt: sudo said no for another reason. Carries what sudo printed.
    case refused(String)
    /// sudo asked another question after the password without saying the password was wrong (a second factor, a
    /// password change). One Ctrl-C was sent. The password itself may be fine, so a saved one is kept.
    case otherPrompt
    /// The stream ended before any marker (cancelled, dropped).
    case unfinished
}

/// Reads the start of a password run: hides the nonce prompt line (sudo-rs wraps it as `[sudo: ##rackoon-sudo-…:]
/// Password:` and echoes an asterisk per typed character, which would show the password's length), asks for the
/// password to be typed at the first prompt only, and settles the outcome from the markers. Once settled, everything
/// passes through untouched and is never looked at again. Chunks can cut a marker anywhere, so an unfinished line that
/// could still become one is held back. Pure.
public struct SudoHandshake: Sendable {
    public enum Action: Sendable, Equatable {
        /// Type the password (and a newline) now.
        case typePassword
        /// Send one Ctrl-C.
        case interrupt
    }

    public static let notice = "\u{1B}[2m[sudo password sent]\u{1B}[0m\r\n"
    public static let rejectedNotice = "\u{1B}[31m[the sudo password was not accepted]\u{1B}[0m\r\n"

    private let prompt: String
    private let ok: String
    private let fail: String
    private var pending = ""
    private var suppressing = false
    private var answered = false
    /// What sudo printed before a fail marker, for the explanation.
    private var seen = ""
    /// What sudo printed after the password was typed: tells a wrong password from another question.
    private var sinceAnswer = ""
    public private(set) var outcome: SudoOutcome?

    public init(nonce: String) {
        prompt = "##rackoon-sudo-\(nonce):"
        ok = "##rackoon-sudo-ok-\(nonce)"
        fail = "##rackoon-sudo-fail-\(nonce)"
    }

    public mutating func push(_ chunk: String) -> (shown: String, actions: [Action]) {
        pending += chunk
        var shown = ""
        var actions: [Action] = []
        while true {
            let s = pending.unicodeScalars
            if suppressing {
                // Drop the rest of a prompt or marker line (the typed-password echo, the marker's line end).
                guard let nl = s.firstIndex(of: "\n") else { pending = ""; break }
                pending = String(s[s.index(after: nl)...])
                suppressing = false
                continue
            }
            if outcome != nil {
                shown += pending
                pending = ""
                break
            }
            // The earliest of the three markers decides what happens next.
            let found = [(prompt, 0), (ok, 1), (fail, 2)].compactMap { m, kind in pending.range(of: m).map { ($0, kind) } }
                .min { $0.0.lowerBound < $1.0.lowerBound }
            if let (range, kind) = found {
                let lineStart = s[..<range.lowerBound].lastIndex(of: "\n").map { s.index(after: $0) } ?? s.startIndex
                let before = String(s[..<lineStart])
                shown += before
                seen += before
                if answered { sinceAnswer += before }
                let wrongPassword = answered && SudoElevation.isAuthFailure(ANSI.strip(sinceAnswer))
                switch kind {
                case 0 where !answered:
                    answered = true
                    actions.append(.typePassword)
                    shown += Self.notice
                case 0:
                    // A second prompt: a wrong password only if sudo said so; otherwise another question (2FA, password
                    // change) whose prompt sudo-rs also wraps with our marker.
                    outcome = wrongPassword ? .rejected : .otherPrompt
                    actions.append(.interrupt)
                    shown += wrongPassword ? Self.rejectedNotice : ""
                case 1:
                    outcome = .accepted
                default:
                    // sudo gave up after the typed password (passwd_tries=1, or a PAM stack that stops at the first
                    // failure): that is a wrong password too.
                    outcome = wrongPassword ? .rejected : .refused(ANSI.strip(seen).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                pending = String(s[range.upperBound...])
                suppressing = true
                continue
            }
            // Hold back the unfinished last line if it could still become a prompt or a marker.
            let tailStart = s.lastIndex(of: "\n").map { s.index(after: $0) } ?? s.startIndex
            let tail = s[tailStart...]
            let tailText = String(tail)
            var holdFrom = s.endIndex
            if !tailText.isEmpty && ("[sudo: ".hasPrefix(tailText) || tailText.hasPrefix("[sudo: ")) {
                holdFrom = tailStart
            } else {
                let markers = [prompt, ok, fail].map { Array($0.unicodeScalars) }
                let longest = markers.map(\.count).max() ?? 0
                search: for length in stride(from: min(longest - 1, tail.count), through: 1, by: -1) {
                    let suffix = Array(tail.suffix(length))
                    for m in markers where m.count > length && Array(m.prefix(length)) == suffix {
                        holdFrom = s.index(s.endIndex, offsetBy: -length)
                        break search
                    }
                }
            }
            let released = String(s[..<holdFrom])
            shown += released
            seen += released
            if answered { sinceAnswer += released }
            pending = String(s[holdFrom...])
            break
        }
        return (shown, actions)
    }

    /// At the end of the stream: what was held back, and `.unfinished` if no marker ever arrived.
    public mutating func finish() -> String {
        defer { pending = "" }
        if outcome == nil { outcome = .unfinished }
        return suppressing ? "" : pending
    }
}
