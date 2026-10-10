import AppKit
import SwiftUI

/// Which build this is. The installed app is the stable one; anything else is a dev build, with its own icon (the mascot
/// with caution tape) so the two can be told apart in the Dock and the app switcher: `swift run` (no bundle), or an app
/// built with `tools/make-app --dev` (bundle id ending in `.dev`).
enum AppBuild {
    static var isDev: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }   // `swift run`: no bundle at all
        return id.hasSuffix(".dev") || Bundle.main.bundleURL.pathExtension != "app"
    }
}

/// The Rackoon mascot. Source of truth is assets/icon/rackoon-icon.svg (and rackoon-icon-dev.svg for dev builds); the
/// bundled PNGs are 1024 px renders of them.
@MainActor
enum AppIcon {
    static let artwork: NSImage? = AppResources.url(forResource: AppBuild.isDev ? "rackoon-icon-dev" : "rackoon-icon", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    /// The artwork is a full-bleed square. The Dock expects the macOS shape: a rounded square inset on a
    /// transparent canvas, so draw it that way. (A real .app bundle would ship an .icns instead.)
    static func dockImage() -> NSImage? {
        guard let artwork else { return nil }
        let canvas = NSSize(width: 1024, height: 1024)
        return NSImage(size: canvas, flipped: false) { _ in
            let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
            NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185).addClip()
            artwork.draw(in: rect)
            return true
        }
    }

    /// Dock icon for `swift run`, where there is no bundle icon.
    static func installDockIcon() {
        // A built app already has its .icns; leave that alone.
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") != nil { return }
        if let image = dockImage() { NSApp.applicationIconImage = image }
    }
}
