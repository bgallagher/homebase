import Foundation
import RackoonCore

/// The tar stream a folder upload sends. The size is needed before the upload starts, because the server checks it
/// (see `LocalSource`); it is found by running the same tar once into a counter.
public enum LocalArchive {
    /// No AppleDouble (._*) companions and no extended attributes in the archive.
    static func tarProcess(for folder: URL) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["--no-xattrs", "-cf", "-", "-C", folder.deletingLastPathComponent().path, "--", folder.lastPathComponent]
        p.environment = ProcessInfo.processInfo.environment.merging(["COPYFILE_DISABLE": "1"]) { $1 }
        return p
    }

    /// Bytes in the tar stream of `folder`. Blocks while tar runs, so call it off the main thread.
    public static func size(of folder: URL) throws -> Int64 {
        let p = tarProcess(for: folder)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        var total: Int64 = 0
        while let data = try? out.fileHandleForReading.read(upToCount: 1 << 20), !data.isEmpty { total += Int64(data.count) }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw TransferError.failed("Couldn't read the folder “\(folder.lastPathComponent)”.") }
        return total
    }
}
