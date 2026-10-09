import Foundation
import XCTest
@testable import HomebaseCore

final class TerminalThemeTests: XCTestCase {
    private let themesURL = repoRoot.appendingPathComponent("apple/Apps/HomebaseMac/Resources/themes.json")

    func testHexParsing() {
        XCTAssertEqual(RGB(hex: "#6D8DFF"), RGB(r: 0x6D, g: 0x8D, b: 0xFF))
        XCTAssertEqual(RGB(hex: "6d8dff"), RGB(r: 0x6D, g: 0x8D, b: 0xFF), "no hash, lowercase")
        XCTAssertEqual(RGB(hex: " #000000 ")?.hex, "#000000")
        for bad in ["", "#FFF", "#12345", "#1234567", "#GGGGGG", "red", "#12 456"] {
            XCTAssertNil(RGB(hex: bad), bad)
        }
        XCTAssertEqual(RGB(hex: "#6D8DFF")?.hex, "#6D8DFF", "round trip")
    }

    func testLuminance() {
        XCTAssertEqual(RGB(hex: "#000000")!.luminance, 0, accuracy: 0.0001)
        XCTAssertEqual(RGB(hex: "#FFFFFF")!.luminance, 1, accuracy: 0.0001)
        XCTAssertLessThan(RGB(hex: "#15171C")!.luminance, 0.05)
        XCTAssertGreaterThan(RGB(hex: "#F5F6F8")!.luminance, 0.9)
    }

    func testBundledCatalogIsValid() throws {
        let themes = try ThemeCatalog.load(from: Data(contentsOf: themesURL))
        XCTAssertTrue(themes.contains { $0.id == ThemeCatalog.defaultID })
        XCTAssertTrue(themes.contains { $0.isDark } && themes.contains { !$0.isDark }, "ships both dark and light")
    }

    private func theme(id: String = "t", appearance: String = "dark", background: String = "#101010",
                       ansi: [String]? = nil) -> TerminalTheme {
        TerminalTheme(id: id, name: id, family: "F", appearance: appearance, background: background,
                      foreground: "#EEEEEE", ansi: ansi ?? Array(repeating: "#808080", count: 16))
    }

    func testValidationRejectsBrokenThemes() {
        let good = theme(id: ThemeCatalog.defaultID)
        XCTAssertNoThrow(try ThemeCatalog.validate([good]))

        XCTAssertThrowsError(try ThemeCatalog.validate([good, good]), "duplicate id")
        XCTAssertThrowsError(try ThemeCatalog.validate([good, theme(ansi: Array(repeating: "#808080", count: 15))]), "15 colours")
        XCTAssertThrowsError(try ThemeCatalog.validate([good, theme(background: "#GGGGGG")]), "bad hex")
        XCTAssertThrowsError(try ThemeCatalog.validate([good, theme(id: "x", appearance: "sepia")]), "bad appearance")
        XCTAssertThrowsError(try ThemeCatalog.validate([good, theme(id: "x", appearance: "light", background: "#101010")]),
                             "labelled light but dark")
        XCTAssertThrowsError(try ThemeCatalog.validate([theme(id: "no-default")]), "default theme must exist")
        var badANSI = Array(repeating: "#808080", count: 16); badANSI[7] = "nope"
        XCTAssertThrowsError(try ThemeCatalog.validate([good, theme(id: "y", ansi: badANSI)]), "bad ANSI entry")
    }

    func testMalformedJSONFailsLoudly() {
        XCTAssertThrowsError(try ThemeCatalog.load(from: Data("[{\"id\": 1}]".utf8)))
        XCTAssertThrowsError(try ThemeCatalog.load(from: Data("not json".utf8)))
    }

    func testMissingCursorAndSelectionFallBack() {
        let t = theme()
        XCTAssertEqual(t.cursorRGB, t.foregroundRGB)
        XCTAssertEqual(t.selectionRGB, t.foregroundRGB)
    }
}
