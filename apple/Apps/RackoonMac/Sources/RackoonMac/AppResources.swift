import Foundation

/// Finds the app's bundled files. SwiftPM's generated `Bundle.module` only looks next to the .app (unsealed, so
/// code signing rejects it) or at the build directory, and traps if neither exists. A built app keeps the resource
/// bundle in Contents/Resources (tools/make-app), so look there first and fall back to `Bundle.module` only under
/// `swift run`, where it works.
enum AppResources {
    private static let bundleName = "Rackoon_RackoonMac.bundle"

    static func url(forResource name: String, withExtension ext: String) -> URL? {
        if let inApp = Bundle.main.resourceURL?.appendingPathComponent(bundleName),
           let bundle = Bundle(url: inApp) {
            return bundle.url(forResource: name, withExtension: ext)
        }
        return Bundle.module.url(forResource: name, withExtension: ext)
    }
}
