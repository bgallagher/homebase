import Foundation
import RackoonCore
import Subprocess

/// The tar stream a folder upload sends. The size is needed before the upload starts, because the server checks it
/// (see `LocalSource`); it is found by running the same tar once into a counter.
public enum LocalArchive {
    /// No AppleDouble (._*) companions and no extended attributes in the archive.
    static func tarArguments(for folder: URL) -> Arguments {
        ["--no-xattrs", "-cf", "-", "-C", folder.deletingLastPathComponent().path, "--", folder.lastPathComponent]
    }

    static let tarEnvironment = Environment.inherit.updating(["COPYFILE_DISABLE": "1"])

    /// Runs tar over `folder` and hands each chunk of the archive to `consume`. Returns when tar has ended.
    static func stream(of folder: URL, _ consume: @escaping @Sendable ([UInt8]) async throws -> Void) async throws {
        let name = folder.lastPathComponent
        let result = try await Subprocess.run(
            .path("/usr/bin/tar"), arguments: tarArguments(for: folder), environment: tarEnvironment,
            input: .none, output: .sequence, error: .discarded
        ) { execution in
            for try await buffer in execution.standardOutput {
                try await consume(buffer.withUnsafeBytes { Array($0) })
            }
        }
        guard result.terminationStatus.isSuccess else { throw TransferError.failed("Couldn't read the folder “\(name)”.") }
    }

    /// Bytes in the tar stream of `folder`.
    public static func size(of folder: URL) async throws -> Int64 {
        let counter = ByteCounter()
        try await stream(of: folder) { counter.add($0.count) }
        return counter.total
    }
}

final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    func add(_ n: Int) { lock.withLock { value += Int64(n) } }
    var total: Int64 { lock.withLock { value } }
}
