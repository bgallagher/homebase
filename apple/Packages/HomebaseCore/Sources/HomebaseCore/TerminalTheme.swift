import Foundation

/// An 8-bit sRGB colour. Hex parsing lives here so themes stay plain data.
public struct RGB: Sendable, Equatable, Hashable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }

    /// "#RRGGBB" or "RRGGBB" (case-insensitive). Anything else, including 3-digit shorthand, is rejected
    /// so a malformed theme file fails loudly instead of rendering a wrong colour.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }

    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }

    /// Linear blend: 0 gives `self`, 1 gives `other`.
    public func mixed(with other: RGB, amount t: Double) -> RGB {
        let k = min(max(t, 0), 1)
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) * (1 - k) + Double(b) * k).rounded()) }
        return RGB(r: mix(r, other.r), g: mix(g, other.g), b: mix(b, other.b))
    }

    public static let black = RGB(r: 0, g: 0, b: 0)
    public static let white = RGB(r: 255, g: 255, b: 255)

    /// WCAG contrast ratio, 1 (identical) to 21 (black on white).
    public func contrastRatio(with other: RGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The best contrast any colour can have against this one (black or white, whichever is further).
    public var bestPossibleContrast: Double { max(contrastRatio(with: .black), contrastRatio(with: .white)) }

    /// `self` if it already has at least `minimum` contrast against `background`; otherwise the closest
    /// colour to `self`, moving toward white or black, that does. If even black/white cannot reach it (a
    /// mid-grey background), returns the best that can be had.
    public func ensuringContrast(against background: RGB, minimum: Double) -> RGB {
        if contrastRatio(with: background) >= minimum { return self }
        let target: RGB = background.contrastRatio(with: .white) >= background.contrastRatio(with: .black) ? .white : .black
        for step in 1...40 {
            let c = mixed(with: target, amount: Double(step) / 40)
            if c.contrastRatio(with: background) >= minimum { return c }
        }
        return target
    }

    /// WCAG relative luminance, 0 (black) to 1 (white).
    public var luminance: Double {
        func lin(_ c: UInt8) -> Double {
            let v = Double(c) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}

/// A terminal colour theme. Stored as JSON with hex strings so any platform can read it.
public struct TerminalTheme: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var family: String
    /// "dark" or "light"
    public var appearance: String
    public var background: String
    public var foreground: String
    public var cursor: String?
    public var selection: String?
    /// The 16 ANSI colours: 0-7 normal (black...white), 8-15 bright.
    public var ansi: [String]

    public init(id: String, name: String, family: String, appearance: String, background: String,
                foreground: String, cursor: String? = nil, selection: String? = nil, ansi: [String]) {
        self.id = id; self.name = name; self.family = family; self.appearance = appearance
        self.background = background; self.foreground = foreground
        self.cursor = cursor; self.selection = selection; self.ansi = ansi
    }

    public var isDark: Bool { appearance == "dark" }

    public var backgroundRGB: RGB { RGB(hex: background) ?? RGB(r: 0, g: 0, b: 0) }
    public var foregroundRGB: RGB { RGB(hex: foreground) ?? RGB(r: 255, g: 255, b: 255) }
    public var ansiRGB: [RGB] { ansi.map { RGB(hex: $0) ?? RGB(r: 128, g: 128, b: 128) } }

    /// Cursor colour, falling back to the foreground when the theme has none.
    public var cursorRGB: RGB { cursor.flatMap(RGB.init(hex:)) ?? foregroundRGB }
    /// Selection colour, falling back to the foreground colour; the UI draws it translucent.
    public var selectionRGB: RGB { selection.flatMap(RGB.init(hex:)) ?? foregroundRGB }
}

public enum ThemeCatalogError: Error, Equatable, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self { case .invalid(let m): "Invalid theme catalogue: \(m)" }
    }
}

public enum ThemeCatalog {
    public static let defaultID = "homebase-dark"
    public static let lightDefaultID = "homebase-light"
    /// Selection id for "follow macOS": Homebase Dark or Light depending on the system appearance.
    public static let automaticID = "automatic"

    /// The theme actually in effect for a saved selection. `automatic` (and any unknown id) follows the system.
    public static func resolve(selection: String, systemIsDark: Bool, in themes: [TerminalTheme]) -> TerminalTheme? {
        if selection != automaticID, let t = themes.first(where: { $0.id == selection }) { return t }
        let wanted = systemIsDark ? defaultID : lightDefaultID
        return themes.first { $0.id == wanted } ?? themes.first { $0.id == defaultID } ?? themes.first
    }

    /// Decodes and validates a theme list: unique ids, 16 valid ANSI colours, valid hex everywhere,
    /// and an appearance label that agrees with the background's luminance.
    public static func load(from data: Data) throws -> [TerminalTheme] {
        let themes: [TerminalTheme]
        do { themes = try JSONDecoder().decode([TerminalTheme].self, from: data) }
        catch { throw ThemeCatalogError.invalid("not valid theme JSON: \(error.localizedDescription)") }
        try validate(themes)
        return themes
    }

    public static func validate(_ themes: [TerminalTheme]) throws {
        var seen = Set<String>()
        for t in themes {
            func bad(_ m: String) -> ThemeCatalogError { .invalid("\(t.id): \(m)") }
            guard !t.id.isEmpty, seen.insert(t.id).inserted else { throw bad("missing or duplicate id") }
            guard t.appearance == "dark" || t.appearance == "light" else { throw bad("appearance must be dark or light") }
            guard let bg = RGB(hex: t.background) else { throw bad("bad background") }
            guard RGB(hex: t.foreground) != nil else { throw bad("bad foreground") }
            if let c = t.cursor, RGB(hex: c) == nil { throw bad("bad cursor") }
            if let s = t.selection, RGB(hex: s) == nil { throw bad("bad selection") }
            guard t.ansi.count == 16 else { throw bad("needs exactly 16 ANSI colours, has \(t.ansi.count)") }
            for (i, c) in t.ansi.enumerated() where RGB(hex: c) == nil { throw bad("bad ANSI colour \(i): \(c)") }
            let looksDark = bg.luminance < 0.4
            guard looksDark == t.isDark else { throw bad("labelled \(t.appearance) but the background is \(looksDark ? "dark" : "light")") }
        }
        guard seen.contains(defaultID), seen.contains(lightDefaultID) else {
            throw ThemeCatalogError.invalid("\(defaultID) and \(lightDefaultID) must both exist (Automatic needs them)")
        }
    }
}
