import Foundation
import XCTest
@testable import RackoonCore

final class AppPaletteTests: XCTestCase {
    private func bundledThemes() throws -> [TerminalTheme] {
        try ThemeCatalog.load(from: Data(contentsOf: repoRoot.appendingPathComponent("apple/Apps/RackoonMac/Resources/themes.json")))
    }

    // MARK: colour maths

    func testMixAndContrast() {
        XCTAssertEqual(RGB.black.mixed(with: .white, amount: 0.5), RGB(r: 128, g: 128, b: 128))
        XCTAssertEqual(RGB.black.mixed(with: .white, amount: 0), .black)
        XCTAssertEqual(RGB.black.mixed(with: .white, amount: 1), .white)
        XCTAssertEqual(RGB.black.mixed(with: .white, amount: 7), .white, "amount is clamped")
        XCTAssertEqual(RGB.black.contrastRatio(with: .white), 21, accuracy: 0.001)
        XCTAssertEqual(RGB.white.contrastRatio(with: .white), 1, accuracy: 0.001)
        XCTAssertEqual(RGB(hex: "#777777")!.contrastRatio(with: .white), 4.48, accuracy: 0.02, "known WCAG reference value")
    }

    func testEnsuringContrastNudgesTowardTheReadableEnd() {
        let darkBG = RGB(hex: "#101010")!
        let dim = RGB(hex: "#303030")!
        let fixed = dim.ensuringContrast(against: darkBG, minimum: 4.5)
        XCTAssertGreaterThanOrEqual(fixed.contrastRatio(with: darkBG), 4.5)
        XCTAssertGreaterThan(fixed.luminance, dim.luminance, "lightened on a dark background")

        let lightBG = RGB(hex: "#F0F0F0")!
        let pale = RGB(hex: "#C0C0C0")!
        let darker = pale.ensuringContrast(against: lightBG, minimum: 4.5)
        XCTAssertGreaterThanOrEqual(darker.contrastRatio(with: lightBG), 4.5)
        XCTAssertLessThan(darker.luminance, pale.luminance, "darkened on a light background")

        let ok = RGB(hex: "#EEEEEE")!
        XCTAssertEqual(ok.ensuringContrast(against: darkBG, minimum: 4.5), ok, "already fine: unchanged")
    }

    func testAnythingIsReachableEvenOnAMidGreyBackground() {
        let mid = RGB(hex: "#777777")!
        XCTAssertGreaterThanOrEqual(mid.bestPossibleContrast, 4.5, "4.5 is always achievable, which is why it is the muted floor")
        let c = RGB(hex: "#808080")!.ensuringContrast(against: mid, minimum: 6)
        XCTAssertGreaterThanOrEqual(c.contrastRatio(with: mid), min(6, mid.bestPossibleContrast) - 0.01,
                                    "an unreachable floor falls back to the best possible")
    }

    func testBlackOrWhiteAlwaysClearsTheOnAccentFloor() {
        // Why accentText needs no clamping: the better of black/white is >= 4.5 against EVERY colour.
        var worst = Double.infinity
        for r in stride(from: 0, through: 255, by: 15) {
            for g in stride(from: 0, through: 255, by: 15) {
                for b in stride(from: 0, through: 255, by: 15) {
                    let c = RGB(r: UInt8(r), g: UInt8(g), b: UInt8(b))
                    worst = min(worst, c.bestPossibleContrast)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(worst, AppPalette.Contrast.onAccent)
    }

    // MARK: Automatic

    func testAutomaticResolution() throws {
        let themes = try bundledThemes()
        XCTAssertEqual(ThemeCatalog.resolve(selection: "automatic", systemIsDark: true, in: themes)?.id, "rackoon-dark")
        XCTAssertEqual(ThemeCatalog.resolve(selection: "automatic", systemIsDark: false, in: themes)?.id, "rackoon-light")
        XCTAssertEqual(ThemeCatalog.resolve(selection: "dracula", systemIsDark: false, in: themes)?.id, "dracula",
                       "an explicit choice ignores the system appearance")
        XCTAssertEqual(ThemeCatalog.resolve(selection: "no-such-theme", systemIsDark: false, in: themes)?.id, "rackoon-light",
                       "an unknown id (a theme removed from the bundle) falls back to Automatic")
        XCTAssertNil(ThemeCatalog.resolve(selection: "automatic", systemIsDark: true, in: []))
    }

    func testCatalogRequiresBothRackoonThemes() {
        let dark = TerminalTheme(id: "rackoon-dark", name: "d", family: "H", appearance: "dark", background: "#101010",
                                 foreground: "#EEEEEE", ansi: Array(repeating: "#808080", count: 16))
        XCTAssertThrowsError(try ThemeCatalog.validate([dark]), "Automatic needs the light one too")
    }

    // MARK: every bundled theme produces a readable app

    func testEveryBundledThemeMeetsTheContrastFloors() throws {
        let themes = try bundledThemes()
        XCTAssertGreaterThanOrEqual(themes.count, 40)
        for t in themes {
            let p = AppPalette.derive(from: t)
            let bg = p.background
            func atLeast(_ name: String, _ c: RGB, _ against: RGB, _ floor: Double) {
                let need = min(floor, against.bestPossibleContrast)
                XCTAssertGreaterThanOrEqual(c.contrastRatio(with: against), need - 0.01,
                    "\(t.id): \(name) \(c.hex) on \(against.hex) is \(String(format: "%.2f", c.contrastRatio(with: against))), needs \(need)")
            }
            atLeast("textPrimary", p.textPrimary, bg, AppPalette.Contrast.primary)
            atLeast("textSecondary", p.textSecondary, bg, AppPalette.Contrast.secondary)
            atLeast("textMuted", p.textMuted, bg, AppPalette.Contrast.muted)
            atLeast("textMuted on card", p.textMuted, p.card, AppPalette.Contrast.muted - 0.7)
            atLeast("accent", p.accent, bg, AppPalette.Contrast.accent)
            atLeast("ok", p.ok, bg, AppPalette.Contrast.status)
            atLeast("warn", p.warn, bg, AppPalette.Contrast.status)
            atLeast("danger", p.danger, bg, AppPalette.Contrast.status)
            atLeast("idle", p.idle, bg, AppPalette.Contrast.status)
            atLeast("accentText on accent", p.accentText, p.accent, AppPalette.Contrast.onAccent)
            atLeast("warnText on warnChip", p.warnText, p.warnChip, AppPalette.Contrast.chipText)
            XCTAssertEqual(p.isDark, t.isDark)
        }
    }

    func testEveryRoleFamilyReadsOnEveryTheme() throws {
        for t in try bundledThemes() {
            let p = AppPalette.derive(from: t)
            func atLeast(_ name: String, _ c: RGB, _ against: RGB, _ floor: Double) {
                let need = min(floor, against.bestPossibleContrast)
                XCTAssertGreaterThanOrEqual(c.contrastRatio(with: against), need - 0.01,
                    "\(t.id): \(name) \(c.hex) on \(against.hex) is \(String(format: "%.2f", c.contrastRatio(with: against))), needs \(need)")
            }
            atLeast("textDim", p.textDim, p.background, AppPalette.Contrast.muted)
            let roles: [(String, AppPalette.PaletteRole)] = [
                ("ok", p.okRole), ("warn", p.warnRole), ("danger", p.dangerRole), ("info", p.info), ("scopeLocal", p.scopeLocal),
                ("scopeTailscale", p.scopeTailscale), ("scopePublic", p.scopePublic),
            ] + p.series.enumerated().map { ("series\($0.offset)", $0.element) }
            for (name, r) in roles {
                atLeast("\(name) mark", r.mark, p.background, AppPalette.Contrast.status)
                atLeast("\(name) mark on card", r.mark, p.card, AppPalette.Contrast.status)
                atLeast("\(name) label", r.label, p.background, AppPalette.Contrast.label)
                atLeast("\(name) label on card", r.label, p.card, AppPalette.Contrast.label)
                atLeast("\(name) onFill", r.onFill, r.fill, AppPalette.Contrast.label)
            }
            XCTAssertEqual(p.series.count, 6)
            XCTAssertEqual(Set(p.series.map(\.mark.hex)).count, 6, "\(t.id): series colours must differ")
        }
    }

    func testSurfacesAreDistinguishableFromTheBackground() throws {
        for t in try bundledThemes() {
            let p = AppPalette.derive(from: t)
            for (name, c) in [("sidebar", p.sidebar), ("card", p.card), ("selection", p.selection), ("border", p.border)] {
                XCTAssertNotEqual(c, p.background, "\(t.id): \(name) must differ from the background")
            }
            XCTAssertGreaterThan(p.border.contrastRatio(with: p.background), 1.12, "\(t.id): borders must be visible")
            XCTAssertGreaterThan(p.selection.contrastRatio(with: p.background), 1.08, "\(t.id): selection must be visible")
        }
    }

    func testDerivationIsDeterministic() throws {
        let t = try bundledThemes()[0]
        XCTAssertEqual(AppPalette.derive(from: t), AppPalette.derive(from: t))
    }

    func testRackoonDarkReproducesTheOriginalDesignClosely() throws {
        // Automatic must still look like the app the user already signed off on.
        let themes = try bundledThemes()
        let p = AppPalette.derive(from: themes.first { $0.id == "rackoon-dark" }!)
        XCTAssertEqual(p.background.hex, "#15171C")
        XCTAssertLessThan(p.sidebar.luminance - p.background.luminance, 0.02)
        XCTAssertGreaterThan(p.sidebar.luminance, p.background.luminance, "sidebar slightly lighter, as in the design")
        XCTAssertGreaterThan(p.card.luminance, p.sidebar.luminance - 0.001)
    }
}
