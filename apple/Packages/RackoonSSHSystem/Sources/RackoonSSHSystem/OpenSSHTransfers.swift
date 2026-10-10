import Foundation
import RackoonCore

/// File transfers over the same multiplexed ssh connection as everything else: the bytes go through the remote
/// command's stdin (upload) or stdout (download), so nothing needs to be installed and nothing depends on the
/// server's sftp subsystem. Folders travel as tar streams. Cancelling the task stops both ends.
extension OpenSSHTransport: FileTransferring {
    public func upload(_ source: LocalSource, remoteCommand: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let run = TransferRun()
        try await withTaskCancellationHandler {
            try await Self.blocking { try Self.pumpUp(source, args: baseArguments() + [remoteCommand], run: run, progress: progress) }
        } onCancel: { run.cancel() }
    }

    public func download(remoteCommand: String, to sink: LocalSink, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let run = TransferRun()
        try await withTaskCancellationHandler {
            try await Self.blocking { try Self.pumpDown(sink, args: baseArguments() + [remoteCommand], run: run, progress: progress) }
        } onCancel: { run.cancel() }
    }

    private static let chunk = 256 * 1024

    /// Runs blocking work (pipes, waiting for a process) on its own dispatch thread, not on the cooperative pool, which a
    /// few long transfers would otherwise fill up and stall.
    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// Collects a pipe's output as it arrives (no thread parked in a read).
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let handle: FileHandle
        init(_ pipe: Pipe) {
            handle = pipe.fileHandleForReading
            handle.readabilityHandler = { [weak self] h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { self?.lock.withLock { self?.data.append(d) } }
            }
        }
        /// Call after the process exited: whatever is left in the pipe, as text.
        func finish() -> String {
            handle.readabilityHandler = nil
            let rest = (try? handle.readToEnd()) ?? Data()
            return lock.withLock { String(decoding: data + rest, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    private static func ssh(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        return p
    }

    private static func tar(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(["COPYFILE_DISABLE": "1"]) { $1 }
        return p
    }

    private static func pumpUp(_ source: LocalSource, args: [String], run: TransferRun, progress: @Sendable (Int64) -> Void) throws {
        signal(SIGPIPE, SIG_IGN)
        let remote = ssh(args)
        let toRemote = Pipe(), errors = Pipe()
        remote.standardInput = toRemote
        remote.standardOutput = FileHandle.nullDevice
        remote.standardError = errors
        let reader: FileHandle
        var staged: URL?
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
        switch source {
        case .file(let url, let bytes):
            do { reader = try FileHandle(forReadingFrom: url) }
            catch { throw TransferError.failed("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)") }
            // The server accepts exactly the size that was confirmed; say so if the file changed while waiting.
            let now = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            if now != bytes { try? reader.close(); throw TransferError.failed("“\(url.lastPathComponent)” changed after you confirmed the upload. Try again.") }
        case .folder(let url, let bytes):
            // Archive to a scratch file first: the exact size is then known, and the folder can't change under the upload.
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("rackoon-upload-\(UUID().uuidString).tar")
            guard FileManager.default.createFile(atPath: file.path, contents: nil), let out = try? FileHandle(forWritingTo: file) else {
                throw TransferError.failed("Couldn't prepare “\(url.lastPathComponent)” for upload.")
            }
            staged = file
            let p = LocalArchive.tarProcess(for: url)
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            run.add(p)
            do { try p.run() } catch { try? out.close(); throw TransferError.failed("Could not launch tar: \(error.localizedDescription)") }
            p.waitUntilExit()
            try? out.close()
            if run.cancelled { throw CancellationError() }
            guard p.terminationStatus == 0 else { throw TransferError.failed("Couldn't read the folder “\(url.lastPathComponent)”.") }
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
            if size != bytes { throw TransferError.failed("“\(url.lastPathComponent)” changed after you confirmed the upload. Try again.") }
            guard let h = try? FileHandle(forReadingFrom: file) else { throw TransferError.failed("Couldn't prepare the upload.") }
            reader = h
        }
        run.add(remote)
        let errorText = Collector(errors)
        do { try remote.run() } catch { throw TransferError.failed("Could not launch ssh: \(error.localizedDescription)") }

        var sent: Int64 = 0
        var writeFailed = false
        while !run.cancelled {
            guard let data = try? reader.read(upToCount: chunk), !data.isEmpty else { break }
            do { try toRemote.fileHandleForWriting.write(contentsOf: data) } catch { writeFailed = true; break }
            sent += Int64(data.count)
            progress(sent)
        }
        try? toRemote.fileHandleForWriting.close()
        try? reader.close()
        if run.cancelled { remote.terminate() }
        remote.waitUntilExit()
        let message = errorText.finish()
        if run.cancelled { throw CancellationError() }
        if remote.terminationStatus != 0 || writeFailed {
            throw TransferError.failed(message.isEmpty ? "The server stopped the upload (status \(remote.terminationStatus))." : message)
        }
    }

    private static func pumpDown(_ sink: LocalSink, args: [String], run: TransferRun, progress: @Sendable (Int64) -> Void) throws {
        signal(SIGPIPE, SIG_IGN)
        let remote = ssh(args)
        let fromRemote = Pipe(), errors = Pipe()
        remote.standardInput = FileHandle.nullDevice
        remote.standardOutput = fromRemote
        remote.standardError = errors
        let writer: FileHandle
        var unpacker: Process?
        switch sink {
        case .file(let url):
            guard FileManager.default.createFile(atPath: url.path, contents: nil), let h = try? FileHandle(forWritingTo: url) else {
                throw TransferError.failed("Couldn't create \(url.lastPathComponent) on this Mac.")
            }
            writer = h
        case .folder(let into):
            let p = tar(["-xf", "-", "-C", into.path])
            let input = Pipe()
            p.standardInput = input
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            unpacker = p
            writer = input.fileHandleForWriting
        }
        run.add(remote)
        if let unpacker { run.add(unpacker) }
        let errorText = Collector(errors)
        do { try remote.run() } catch { throw TransferError.failed("Could not launch ssh: \(error.localizedDescription)") }
        do { try unpacker?.run() } catch { remote.terminate(); throw TransferError.failed("Could not launch tar: \(error.localizedDescription)") }

        var received: Int64 = 0
        var writeFailed = false
        while !run.cancelled {
            guard let data = try? fromRemote.fileHandleForReading.read(upToCount: chunk), !data.isEmpty else { break }
            do { try writer.write(contentsOf: data) } catch { writeFailed = true; break }
            received += Int64(data.count)
            progress(received)
        }
        try? writer.close()
        if run.cancelled || writeFailed { remote.terminate() }
        remote.waitUntilExit()
        unpacker?.waitUntilExit()
        let message = errorText.finish()
        if run.cancelled { throw CancellationError() }
        if remote.terminationStatus != 0 || writeFailed {
            throw TransferError.failed(message.isEmpty ? "The transfer failed (status \(remote.terminationStatus))." : message)
        }
        if let unpacker, unpacker.terminationStatus != 0 { throw TransferError.failed("Couldn't unpack the folder on this Mac.") }
    }
}

private final class TransferRun: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Process] = []
    private var isCancelled = false

    func add(_ p: Process) { lock.withLock { processes.append(p) } }
    var cancelled: Bool { lock.withLock { isCancelled } }
    func cancel() {
        let all: [Process] = lock.withLock { isCancelled = true; return processes }
        for p in all where p.isRunning { p.terminate() }
    }
}
