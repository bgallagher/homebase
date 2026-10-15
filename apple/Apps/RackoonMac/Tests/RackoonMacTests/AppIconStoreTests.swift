import AppKit
@testable import RackoonCore
import XCTest
@testable import RackoonMac

/// The icon store's file handling: uploads, the disk cache, saved choices and download failures. Nothing here touches the
/// network: only ids that are already on disk, the user's own images and `finish` (the end of a download) are used.
@MainActor
final class AppIconStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rackoon-icons-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A solid-colour PNG of the given size.
    private func png(width: Int, height: Int, red: CGFloat = 1) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(red: red, green: 0.2, blue: 0.4, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private let stack = DockerStack(name: "app", workingDir: nil, configFile: nil, configFiles: [], containers: [
        DockerContainer(id: "abcdef012345", name: "app", image: "binhex/arch-delugevpn", state: "running", health: "none", status: "Up",
                        ports: [], iconURL: "https://example.invalid/deluge.png"),
    ], isStandalone: true)

    func testUploadIsRedrawnSquareKeptAndChosen() async throws {
        let store = AppIconStore(directory: directory)
        let imported = await store.importImage(at: try write(png(width: 300, height: 120), "wide.png"))
        let id = try XCTUnwrap(imported)
        guard case .custom(let hex) = AppIconRef(id: id) else { return XCTFail("not a custom id: \(id)") }
        XCTAssertEqual(hex.count, 32)
        let file = directory.appendingPathComponent("custom/\(hex).png")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: file)))
        XCTAssertEqual([rep.pixelsWide, rep.pixelsHigh], [256, 256], "redrawn as a 256 px square, letterboxed")
        XCTAssertEqual(store.customIcons, [id])
        XCTAssertNotNil(store.image(id))

        store.choose(id, for: stack, server: "srv")
        XCTAssertEqual(store.stackIcon(stack, server: "srv"), id)
        // Saved, and read back by the next launch.
        let reopened = AppIconStore(directory: directory)
        XCTAssertEqual(reopened.stackIcon(stack, server: "srv"), id)
        XCTAssertEqual(reopened.customIcons, [id])
        XCTAssertNotNil(reopened.image(id), "read from disk on first use")
    }

    func testTheSamePictureTwiceIsStoredOnce() async throws {
        let store = AppIconStore(directory: directory)
        let data = png(width: 64, height: 64)
        let first = await store.importImage(at: try write(data, "a.png"))
        let second = await store.importImage(at: try write(data, "b.png"))
        let other = await store.importImage(at: try write(png(width: 64, height: 64, red: 0), "c.png"))
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(store.customIcons, [other, first].compactMap { $0 }, "newest first, no duplicate")
    }

    func testNonImagesAndHugeFilesAreRefused() async throws {
        let store = AppIconStore(directory: directory)
        let text = await store.importImage(at: try write(Data("not an image".utf8), "x.png"))
        XCTAssertNil(text)
        let huge = await store.importImage(at: try write(Data(count: AppIconStore.maxImportBytes + 1), "huge.png"))
        XCTAssertNil(huge, "over 8 MB is refused before it is read")
        let missing = await store.importImage(at: directory.appendingPathComponent("nope.png"))
        XCTAssertNil(missing)
        XCTAssertTrue(store.customIcons.isEmpty)
    }

    func testDeletingAnImageResetsTheChoicesThatUsedIt() async throws {
        let store = AppIconStore(directory: directory)
        let imported = await store.importImage(at: try write(png(width: 32, height: 32), "a.png"))
        let id = try XCTUnwrap(imported)
        store.choose(id, for: stack, server: "srv")
        store.choose(id, for: stack, service: stack.containers[0], server: "srv")
        store.deleteCustom(id)
        XCTAssertTrue(store.customIcons.isEmpty)
        XCTAssertNil(store.image(id))
        XCTAssertFalse(store.isChosen(stack, server: "srv"))
        XCTAssertFalse(store.isChosen(stack, service: stack.containers[0], server: "srv"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("custom").path + "/" + id.dropFirst(7) + ".png"))
        XCTAssertFalse(AppIconStore(directory: directory).isChosen(stack, server: "srv"), "the reset is saved")
    }

    func testJunkInTheChoicesFileIsIgnored() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let junk = ["srv|standalone/app": "../../etc/passwd", "srv|other": "url:https://x.y/a.png", "srv|ok": "redis"]
        try JSONEncoder().encode(junk).write(to: directory.appendingPathComponent("choices.json"))
        let store = AppIconStore(directory: directory)
        XCTAssertFalse(store.isChosen(stack, server: "srv"), "a path is never used as an icon")
        XCTAssertEqual(store.choices.overrides, ["srv|ok": "redis"])
    }

    func testAFailedTemplateDownloadFallsBackToTheGuessAndASuccessIsKept() throws {
        let store = AppIconStore(directory: directory)
        let template = "url:https://example.invalid/deluge.png"
        XCTAssertEqual(store.stackIcon(stack, server: "srv"), template, "no catalog yet: the template icon")
        store.finish(template, nil)
        XCTAssertNil(store.stackIcon(stack, server: "srv"), "failed, and no catalog to guess from yet")

        let id = "sh:example"
        store.finish(id, png(width: 10, height: 10))
        XCTAssertNotNil(store.image(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("icons-selfhst/example.png").path))
        store.finish("redis", Data("garbage".utf8))
        XCTAssertNil(store.image("redis"), "an undecodable download is a failure, not an empty icon")
        XCTAssertTrue(store.queue.hasFailed("redis"))
    }

    func testIconsAlreadyOnDiskAreNotDownloaded() throws {
        let icons = directory.appendingPathComponent("icons", isDirectory: true)
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        try png(width: 16, height: 16).write(to: icons.appendingPathComponent("jellyfin.png"))
        let store = AppIconStore(directory: directory)
        store.ensure(["jellyfin", "custom:0123456789abcdef"])
        XCTAssertTrue(store.fetching.isEmpty, "on disk, or the user's own: nothing to fetch")
        XCTAssertNotNil(store.image("jellyfin"))
        XCTAssertNil(store.image("custom:0123456789abcdef"))
    }

    func testForgetRemovesOnlyThatServersChoices() {
        let store = AppIconStore(directory: directory)
        store.choose("redis", for: stack, server: "srv")
        store.choose("redis", for: stack, server: "srv2")
        store.forget(serverID: "srv")
        XCTAssertFalse(store.isChosen(stack, server: "srv"))
        XCTAssertTrue(store.isChosen(stack, server: "srv2"))
    }

    func testRenderPNGSizes() throws {
        let data = png(width: 50, height: 200)
        for side in [128, 256] {
            let rep = try XCTUnwrap(FaviconStore.renderPNG(data, side: side).flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertEqual([rep.pixelsWide, rep.pixelsHigh], [side, side])
        }
        XCTAssertNil(FaviconStore.renderPNG(Data("nope".utf8)))
    }
}
