import Foundation
@testable import RackoonCore

/// Repo root, found from this file's location (<root>/apple/Packages/RackoonCore/Tests/RackoonCoreTests/).
let repoRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { url.deleteLastPathComponent() }
    return url
}()

var specDir: URL { repoRoot.appendingPathComponent("spec") }

/// Replays canned output; records what it was asked to run.
final class FakeTransport: SSHTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<CommandResult, Error>]
    private(set) var commands: [String] = []

    init(_ responses: [Result<CommandResult, Error>]) { queue = responses }

    func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        try next(command).get()
    }

    private func next(_ command: String) -> Result<CommandResult, Error> {
        lock.lock(); defer { lock.unlock() }
        commands.append(command)
        guard !queue.isEmpty else { return .success(CommandResult(stdout: "", exitCode: 1)) }
        return queue.count > 1 ? queue.removeFirst() : queue[0]
    }

    func stream(_ command: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
