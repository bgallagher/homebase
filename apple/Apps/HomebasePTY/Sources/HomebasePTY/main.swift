import Darwin
import Foundation
import HomebaseCore

// homebase-pty: a pseudo-terminal relay that sits between a terminal view and a command (ssh).
//
//   homebase-pty [--no-highlight] -- <command> [args...]
//
// It runs <command> on its own pty, copies input from our terminal to it unchanged, and copies the command's
// output back through TerminalOutputFilter, which adds colour to IP addresses, errors and so on. SwiftTerm's
// own view stays untouched: it just thinks it is talking to a program. Window resizes are forwarded, and the
// exit status of <command> becomes ours.

nonisolated(unsafe) var winchPending: sig_atomic_t = 0
nonisolated(unsafe) var hangupPending: sig_atomic_t = 0

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: homebase-pty [--no-highlight] -- <command> [args...]\n".utf8))
    exit(64)
}

func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
    var offset = 0
    while offset < bytes.count {
        let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n < 0 {
            if errno == EINTR || errno == EAGAIN { continue }
            return
        }
        offset += n
    }
}

var args = Array(CommandLine.arguments.dropFirst())
var highlight = true
if args.first == "--no-highlight" { highlight = false; args.removeFirst() }
guard args.first == "--", args.count >= 2 else { usage() }
args.removeFirst()

// Everything the child needs is built before forkpty: after fork only async-signal-safe calls are allowed.
let cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]

let outerIsTTY = isatty(STDIN_FILENO) == 1
var original = termios()
var size = winsize()
if outerIsTTY {
    tcgetattr(STDIN_FILENO, &original)
    _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &size)
}

var master: Int32 = -1
let pid: pid_t = outerIsTTY ? forkpty(&master, nil, &original, &size) : forkpty(&master, nil, nil, nil)
if pid < 0 {
    perror("homebase-pty: forkpty")
    exit(71)
}
if pid == 0 {
    execvp(cArgs[0], cArgs)
    _exit(127)
}

// Our side of the outer terminal must be raw so bytes pass through untouched (the inner pty does the line editing).
if outerIsTTY {
    var raw = original
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
}

signal(SIGWINCH) { _ in winchPending = 1 }
signal(SIGHUP) { _ in hangupPending = 1 }
signal(SIGTERM) { _ in hangupPending = 1 }
signal(SIGPIPE, SIG_IGN)

var filter = TerminalOutputFilter()
filter.isEnabled = highlight
var buffer = [UInt8](repeating: 0, count: 65_536)
var stdinOpen = true
var hangupDeadline: Date?

mainLoop: while true {
    if winchPending != 0 {
        winchPending = 0
        if outerIsTTY, ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0 { _ = ioctl(master, TIOCSWINSZ, &size) }
    }
    if hangupPending != 0, hangupDeadline == nil {
        // Our terminal went away or we were told to stop: hang up the command, then drain until it exits.
        kill(pid, SIGHUP)
        hangupDeadline = Date().addingTimeInterval(2)
    }
    if let d = hangupDeadline, Date() > d {
        kill(pid, SIGKILL)
        hangupDeadline = Date().addingTimeInterval(60)
    }

    var fds = [pollfd(fd: STDIN_FILENO, events: stdinOpen ? Int16(POLLIN) : 0, revents: 0),
               pollfd(fd: master, events: Int16(POLLIN), revents: 0)]
    let ready = poll(&fds, 2, 200)
    if ready < 0 {
        if errno == EINTR { continue }
        break
    }
    if fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
        let n = read(STDIN_FILENO, &buffer, buffer.count)
        if n > 0 { writeAll(master, Array(buffer[0..<n])) } else if n == 0 || (errno != EINTR && errno != EAGAIN) { stdinOpen = false }
    }
    if fds[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
        let n = read(master, &buffer, buffer.count)
        if n > 0 {
            writeAll(STDOUT_FILENO, filter.process(Array(buffer[0..<n])))
        } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
            break mainLoop   // the command closed its terminal: it has exited
        }
    }
}

writeAll(STDOUT_FILENO, filter.finish())
var status: Int32 = 0
waitpid(pid, &status, 0)
if outerIsTTY { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
let exited = (status & 0x7F) == 0
exit(exited ? (status >> 8) & 0xFF : 128 + (status & 0x7F))
