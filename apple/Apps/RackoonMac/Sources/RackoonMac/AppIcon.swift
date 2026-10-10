import AppKit
import SwiftUI

/// The Rackoon mascot. Source of truth is assets/icon/rackoon-icon.svg; the bundled PNG is a 1024 px render of it.
@MainActor
enum AppIcon {
    static let artwork: NSImage? = AppResources.url(forResource: "rackoon-icon", withExtension: "png")
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
