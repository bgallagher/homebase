import Foundation
import RackoonCore
import Subprocess

/// File transfers over the same multiplexed ssh connection as everything else: the bytes go through the remote
/// command's stdin (upload) or stdout (download), so nothing needs to be installed and nothing depends on the server's
/// sftp subsystem. Folders travel as tar streams. Cancelling the task stops every process involved (swift-subprocess ends
/// a child when its task is cancelled).
extension OpenSSHTransport: FileTransferring {
    private static let chunk = 256 * 1024
    private static let errorLimit = 1 << 20

    public func upload(_ source: LocalSource, remoteCommand: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        signal(SIGPIPE, SIG_IGN)
        let args = Arguments(baseArguments() + [remoteCommand])
        switch source {
        case .file(let url, let bytes):
            // The server accepts exactly the size that was confirmed; say so if the file changed while waiting.
            let now = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            guard now == bytes else { throw Self.changed(url) }
            let reader: FileHandle
            do { reader = try FileHandle(forReadingFrom: url) }
            catch { throw TransferError.failed("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)") }
            defer { try? reader.close() }
            try await Self.send(args: args, progress: progress) { write in
                while let data = try reader.read(upToCount: Self.chunk), !data.isEmpty {
                    try Task.checkCancellation()
                    try await write(Array(data))
                }
            }
        case .folder(let url, let bytes):
            // Archive to a scratch file first: the exact size is then known, and the folder can't change under the upload.
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rackoon-upload-\(UUID().uuidString).tar")
            defer { try? FileManager.default.removeItem(at: scratch) }
            guard FileManager.default.createFile(atPath: scratch.path, contents: nil), let out = try? FileHandle(forWritingTo: scratch) else {
                throw TransferError.failed("Couldn't prepare “\(url.lastPathComponent)” for upload.")
            }
            do {
                try await LocalArchive.stream(of: url) { chunk in try out.write(contentsOf: chunk) }
                try out.close()
            } catch {
                try? out.close()
                throw error
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: scratch.path)[.size] as? NSNumber)?.int64Value
            guard size == bytes else { throw Self.changed(url) }
            guard let reader = try? FileHandle(forReadingFrom: scratch) else { throw TransferError.failed("Couldn't prepare the upload.") }
            defer { try? reader.close() }
            try await Self.send(args: args, progress: progress) { write in
                while let data = try reader.read(upToCount: Self.chunk), !data.isEmpty {
                    try Task.checkCancellation()
                    try await write(Array(data))
                }
            }
        }
    }

    private static func changed(_ url: URL) -> TransferError {
        TransferError.failed("“\(url.lastPathComponent)” changed after you confirmed the upload. Try again.")
    }

    /// Runs ssh with `feed` writing to its stdin, then waits for it and turns a failure into the server's own message.
    private static func send(args: Arguments, progress: @Sendable (Int64) -> Void,
                             feed: @escaping (_ write: ([UInt8]) async throws -> Void) async throws -> Void) async throws {
        let sent = ByteCounter()
        let writeFailed = Flag()
        let result: ExecutionResult<Void, DiscardedOutput, BytesOutput>
        do {
            result = try await Subprocess.run(
                .path("/usr/bin/ssh"), arguments: args, input: .inputWriter, output: .discarded, error: .bytes(limit: errorLimit)
            ) { execution in
                let writer = execution.standardInputWriter
                do {
                    try await feed { bytes in
                        _ = try await writer.write(bytes)
                        sent.add(bytes.count)
                        progress(sent.total)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // ssh went away mid-upload (its error text is in the result): stop writing and let `run` finish.
                    writeFailed.set()
                }
                try? await writer.finish()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw TransferError.failed("Could not run ssh: \(error)")
        }
        if Task.isCancelled { throw CancellationError() }
        let message = String(decoding: result.standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.terminationStatus.isSuccess || writeFailed.isSet {
            throw TransferError.failed(message.isEmpty ? "The server stopped the upload (status \(result.terminationStatus))." : message)
        }
    }

    public func download(remoteCommand: String, to sink: LocalSink, progress: @escaping @Sendable (Int64) -> Void) async throws {
        signal(SIGPIPE, SIG_IGN)
        let args = Arguments(baseArguments() + [remoteCommand])
        switch sink {
        case .file(let url):
            guard FileManager.default.createFile(atPath: url.path, contents: nil), let writer = try? FileHandle(forWritingTo: url) else {
                throw TransferError.failed("Couldn't create \(url.lastPathComponent) on this Mac.")
            }
            defer { try? writer.close() }
            try await Self.receive(args: args, progress: progress) { bytes in try writer.write(contentsOf: bytes) }
        case .folder(let into):
            // ssh's stdout is piped into `tar -x` running here.
            let tarFailed = Flag()
            let tar = try await Self.runTar(extractingInto: into) { writeToTar in
                try await Self.receive(args: args, progress: progress) { bytes in try await writeToTar(bytes) }
            } onTarWriteFailure: { tarFailed.set() }
            if Task.isCancelled { throw CancellationError() }
            if tarFailed.isSet || !tar.isSuccess { throw TransferError.failed("Couldn't unpack the folder on this Mac.") }
        }
    }

    /// Runs `tar -xf - -C into` and hands `body` a function that writes to its stdin; closes the stdin afterwards.
    private static func runTar(extractingInto into: URL, body: @escaping (_ write: @escaping @Sendable ([UInt8]) async throws -> Void) async throws -> Void,
                               onTarWriteFailure: @escaping @Sendable () -> Void) async throws -> TerminationStatus {
        let result = try await Subprocess.run(
            .path("/usr/bin/tar"), arguments: ["-xf", "-", "-C", into.path], environment: LocalArchive.tarEnvironment,
            input: .inputWriter, output: .discarded, error: .discarded
        ) { execution in
            let writer = execution.standardInputWriter
            do {
                try await body { bytes in
                    do { _ = try await writer.write(bytes) } catch { onTarWriteFailure(); throw error }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TransferError {
                try? await writer.finish()
                throw error
            } catch {
                // tar stopped reading (a bad archive): its failure shows in the status
            }
            try? await writer.finish()
        }
        return result.terminationStatus
    }

    /// Runs ssh and hands each chunk of its stdout to `consume`; a failing ssh becomes the server's own message.
    private static func receive(args: Arguments, progress: @Sendable (Int64) -> Void,
                                consume: @escaping @Sendable ([UInt8]) async throws -> Void) async throws {
        let received = ByteCounter()
        let result: ExecutionResult<Void, SequenceOutput, BytesOutput>
        do {
            result = try await Subprocess.run(
                .path("/usr/bin/ssh"), arguments: args, input: .none, output: .sequence, error: .bytes(limit: errorLimit)
            ) { execution in
                for try await buffer in execution.standardOutput {
                    let bytes = buffer.withUnsafeBytes { Array($0) }
                    try await consume(bytes)
                    received.add(bytes.count)
                    progress(received.total)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TransferError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw TransferError.failed("The transfer failed: \(error)")
        }
        if Task.isCancelled { throw CancellationError() }
        let message = String(decoding: result.standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.terminationStatus.isSuccess {
            throw TransferError.failed(message.isEmpty ? "The transfer failed (status \(result.terminationStatus))." : message)
        }
    }
}

/// A flag set from inside a run body and read after it.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
